#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <signal.h>
#import <unistd.h>

// Load optional MobileDevice entry points at runtime. An unavailable API must not
// prevent AutoSign from starting or using Xcode's full installation path.
typedef void *DeviceRef;
typedef void *ServiceRef;
static CFArrayRef (*deviceList)(void);
static CFStringRef (*deviceIdentifier)(DeviceRef);
static int (*connectDevice)(DeviceRef);
static int (*validatePairing)(DeviceRef);
static int (*startSession)(DeviceRef);
static int (*stopSession)(DeviceRef);
static int (*disconnectDevice)(DeviceRef);
static int (*startService)(DeviceRef, CFStringRef, CFDictionaryRef, ServiceRef *);
static int (*sendMessage)(ServiceRef, CFPropertyListRef, CFPropertyListFormat);
static int (*receiveMessage)(ServiceRef, CFPropertyListRef *, CFPropertyListFormat *);
static void (*invalidateService)(ServiceRef);
static const char *(*errorString)(int);

static void timeoutHandler(int signum) {
    const char message[] = "{\"kind\":\"unavailable\",\"message\":\"设备描述文件服务超时，请解锁设备后重试。\"}\n";
    write(STDOUT_FILENO, message, sizeof(message) - 1);
    _exit(11);
}

static int reply(NSDictionary *value, int code) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    [[NSFileHandle fileHandleWithStandardOutput] writeData:data];
    [[NSFileHandle fileHandleWithStandardOutput] writeData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
    return code;
}

static int fail(NSString *kind, NSString *message, int status) {
    const char *description = errorString ? errorString(status) : NULL;
    return reply(@{@"kind": kind, @"message": message, @"status": @(status),
                   @"detail": description ? @(description) : @""}, 11);
}

static NSDictionary *exchange(ServiceRef service, NSDictionary *request, int *status) {
    *status = sendMessage(service, (__bridge CFDictionaryRef)request, kCFPropertyListXMLFormat_v1_0);
    if (*status != 0) return nil;
    CFPropertyListRef response = NULL;
    *status = receiveMessage(service, &response, NULL);
    if (*status != 0) { if (response) CFRelease(response); return nil; }
    id value = CFBridgingRelease(response);
    return [value isKindOfClass:NSDictionary.class] ? value : nil;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        signal(SIGALRM, timeoutHandler);
        alarm(40);
        if (argc < 3 || (strcmp(argv[1], "list") != 0 && strcmp(argv[1], "install") != 0)
            || (strcmp(argv[1], "install") == 0 && argc != 4)) {
            return reply(@{@"kind": @"invalid", @"message": @"Usage: AutoSignDeviceHelper list UDID | install UDID PROFILE"}, 2);
        }
        void *framework = dlopen("/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice", RTLD_NOW | RTLD_LOCAL);
        if (!framework) return reply(@{@"kind": @"unsupported", @"message": @"当前系统没有可用的 MobileDevice 描述文件服务。"}, 10);
#define LOAD(variable, name) do { variable = dlsym(framework, name); if (!variable) \
    return reply(@{@"kind": @"unsupported", @"message": @"当前系统不支持单独管理描述文件：" @name}, 10); } while (0)
        LOAD(deviceList, "AMDCreateDeviceList");
        LOAD(deviceIdentifier, "AMDeviceCopyDeviceIdentifier");
        LOAD(connectDevice, "AMDeviceConnect");
        LOAD(validatePairing, "AMDeviceValidatePairing");
        LOAD(startSession, "AMDeviceStartSession");
        LOAD(stopSession, "AMDeviceStopSession");
        LOAD(disconnectDevice, "AMDeviceDisconnect");
        LOAD(startService, "AMDeviceSecureStartService");
        LOAD(sendMessage, "AMDServiceConnectionSendMessage");
        LOAD(receiveMessage, "AMDServiceConnectionReceiveMessage");
        LOAD(invalidateService, "AMDServiceConnectionInvalidate");
        errorString = dlsym(framework, "AMDErrorString");
#undef LOAD
        NSString *udid = @(argv[2]);
        CFArrayRef devices = deviceList();
        DeviceRef device = NULL;
        if (devices) {
            for (CFIndex index = 0; index < CFArrayGetCount(devices); index++) {
                DeviceRef candidate = (DeviceRef)CFArrayGetValueAtIndex(devices, index);
                NSString *identifier = CFBridgingRelease(deviceIdentifier(candidate));
                if ([identifier isEqualToString:udid]) { device = candidate; break; }
            }
        }
        if (!device) {
            if (devices) CFRelease(devices);
            return fail(@"unavailable", @"未找到目标设备，请检查 USB 或 Wi-Fi 配对连接。", 0);
        }
        BOOL connected = NO, session = NO;
        ServiceRef service = NULL;
        int result = 0;
        @try {
            int status = connectDevice(device);
            if (status) return fail(@"unavailable", @"无法连接目标设备。", status);
            connected = YES;
            status = validatePairing(device);
            if (status) return fail(@"unavailable", @"设备配对验证失败，请解锁设备并确认信任。", status);
            status = startSession(device);
            if (status) return fail(@"unavailable", @"无法启动设备会话，请解锁设备。", status);
            session = YES;
            status = startService(device, CFSTR("com.apple.misagent"), NULL, &service);
            if (status || !service) {
                // InvalidService is a capability failure; locked/offline devices are not.
                return fail((uint32_t)status == 0xe8000022 ? @"unsupported" : @"unavailable",
                            @"无法启动设备的描述文件服务。", status);
            }
            NSDictionary *request;
            if (strcmp(argv[1], "install") == 0) {
                NSData *profile = [NSData dataWithContentsOfFile:@(argv[3])];
                if (!profile.length || profile.length > 16 * 1024 * 1024)
                    return fail(@"invalid", @"描述文件不存在或大小无效。", 0);
                request = @{@"MessageType": @"Install", @"ProfileType": @"Provisioning", @"Profile": profile};
            } else {
                request = @{@"MessageType": @"CopyAll", @"ProfileType": @"Provisioning"};
            }
            NSDictionary *response = exchange(service, request, &status);
            if (!response) return fail(@"unavailable", @"设备描述文件服务没有返回有效响应。", status);
            if (![response[@"Status"] isKindOfClass:NSNumber.class])
                return fail(@"unsupported", @"设备描述文件服务响应格式不兼容。", 0);
            int profileStatus = [response[@"Status"] intValue];
            if (profileStatus != 0) {
                // A refusal from misagent is different from a transport failure.
                // Banned profiles cannot be repaired by reinstalling an app.
                NSString *kind = (uint32_t)profileStatus == 0xe8008024 ? @"invalid" : @"rejected";
                return fail(kind, @"设备拒绝单独更新描述文件。", profileStatus);
            }
            if (strcmp(argv[1], "install") == 0) {
                result = reply(@{@"kind": @"success"}, 0);
            } else {
                id payload = response[@"Payload"];
                if (![payload isKindOfClass:NSArray.class]) return fail(@"unsupported", @"设备没有返回可读取的描述文件列表。", 0);
                NSMutableArray *profiles = [NSMutableArray array];
                for (id value in payload) {
                    if (![value isKindOfClass:NSData.class]) return fail(@"unsupported", @"描述文件列表包含不兼容的数据。", 0);
                    [profiles addObject:[value base64EncodedStringWithOptions:0]];
                }
                result = reply(@{@"kind": @"success", @"profiles": profiles}, 0);
            }
        } @finally {
            if (service) invalidateService(service);
            if (session) stopSession(device);
            if (connected) disconnectDevice(device);
            if (devices) CFRelease(devices);
        }
        return result;
    }
}
