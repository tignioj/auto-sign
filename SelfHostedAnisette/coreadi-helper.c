// CoreADI ABI reference: Dadoum/apple-crates f9cbefde2bf72fa9becfedc8da64827d4549849a,
// adi/src/{calls,core_adi}.rs. Only calls Apple's installed DLL; no OTP algorithm is implemented.
#include <windows.h>
#include <wincrypt.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct { void *payload; uint32_t input_size, output_size, flags; } Parameters;
typedef int32_t (*Dispatcher)(uint32_t, const Parameters*);
static Dispatcher dispatch;
static uint8_t payload[256];
static size_t offset;
static void put32(uint32_t x) { for(int i=0;i<4;i++)payload[offset++]=(uint8_t)(x>>(24-8*i)); }
static void put64(uint64_t x) { for(int i=0;i<8;i++)payload[offset++]=(uint8_t)(x>>(56-8*i)); }
static void pointer(const void *p) { put64((uintptr_t)p); }
static void begin(void) { offset=0;put32(1);put32(1); }
static int32_t invoke(uint32_t code) {
 Parameters params={payload,(uint32_t)offset,4,0};
 int32_t result=dispatch(code,&params); if(result<0)return result;
 return (int32_t)(((uint32_t)payload[0]<<24)|((uint32_t)payload[1]<<16)|((uint32_t)payload[2]<<8)|payload[3]);
}
static void dispose(void *p) { if(p) {begin();pointer(p);invoke(0x3e58e7f9);} }
static uint8_t *decode(const char *s, DWORD *len) {
 if(!s || strlen(s)>524288)return NULL;
 *len=0;if(!CryptStringToBinaryA(s,0,CRYPT_STRING_BASE64,NULL,len,NULL,NULL) || *len>393216)return NULL;
 uint8_t *data=malloc(*len?*len:1);
 if(!data || !CryptStringToBinaryA(s,0,CRYPT_STRING_BASE64,data,len,NULL,NULL)) {free(data);return NULL;}
 return data;
}
static char *encode(const uint8_t *data, DWORD len) {
 if(!data || !len || len>393216)return NULL;
 DWORD count=0; if(!CryptBinaryToStringA(data,len,CRYPT_STRING_BASE64|CRYPT_STRING_NOCRLF,NULL,&count))return NULL;
 char *s=malloc(count);
 if(!s || !CryptBinaryToStringA(data,len,CRYPT_STRING_BASE64|CRYPT_STRING_NOCRLF,s,&count)){free(s);return NULL;}
 return s;
}
static void status(int32_t code) {printf("{\"status\":%ld}\n",(long)code);fflush(stdout);}
int main(void) {
 const char *dll=getenv("AUTOSIGN_COREADI_DLL");
 if(!dll)dll="Z:\\opt\\autosign\\CoreADI64.dll";
 HMODULE module=LoadLibraryExA(dll,NULL,LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR|LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
 if(!module) {status(-(int32_t)GetLastError());return 1;}
 dispatch=(Dispatcher)GetProcAddress(module,"vdfut768ig");
 if(!dispatch) {status(-45019);return 1;}
 begin();int32_t initialized=invoke(0x12db31c5);
 if(initialized<0) {status(initialized);return 1;}
 char *line=malloc(1048576); if(!line)return 1;
 while(fgets(line,1048576,stdin)) {
  if(!strchr(line,'\n')){status(-45001);break;}
  char *command=strtok(line," \r\n"); if(!command)continue;
  if(!strcmp(command,"start")) {
   DWORD len=0;uint8_t *spim=decode(strtok(NULL," \r\n"),&len);
   if(!spim){status(-45001);continue;}
   const uint8_t *cpim=NULL;uint32_t cpim_len=0,session=0;
   begin();put64((uint64_t)-2);pointer(spim);put32(len);pointer(&cpim);pointer(&cpim_len);pointer(&session);
   int32_t code=invoke(0x716bd86c);free(spim);
   char *encoded=code<0?NULL:encode(cpim,cpim_len);
   if(encoded)printf("{\"status\":%ld,\"cpim\":\"%s\",\"session\":%u}\n",(long)code,encoded,session);
   else status(code<0?code:-45001);
   dispose((void*)cpim);free(encoded);
  } else if(!strcmp(command,"finish")) {
   char *s=strtok(NULL," \r\n");uint32_t session=s?(uint32_t)strtoul(s,NULL,10):0;
   DWORD ptm_len=0,tk_len=0;uint8_t *ptm=decode(strtok(NULL," \r\n"),&ptm_len);uint8_t *tk=decode(strtok(NULL," \r\n"),&tk_len);
   char *r=strtok(NULL," \r\n");uint64_t routing=r?strtoull(r,NULL,10):0;
   if(!session||!ptm||!tk||!routing){free(ptm);free(tk);status(-45001);continue;}
   begin();put32(session);pointer(ptm);put32(ptm_len);pointer(tk);put32(tk_len);
   int32_t code=invoke(0x0b2b3196);free(ptm);free(tk);
   if(code>=0){begin();put64((uint64_t)-2);put64(routing);code=invoke(0x632b8d6e);}
   status(code);
  } else if(!strcmp(command,"headers")) {
   int32_t code=0;char *sim_string=strtok(NULL," \r\n");
   if(sim_string) {
    DWORD sim_len=0;uint8_t *sim=decode(sim_string,&sim_len);const uint8_t *mid=NULL,*srm=NULL;uint32_t mid_len=0,srm_len=0;
    if(!sim){status(-45001);continue;}
    begin();put64((uint64_t)-2);pointer(sim);put32(sim_len);pointer(&mid);pointer(&mid_len);pointer(&srm);pointer(&srm_len);
    code=invoke(0xa54951ec);free(sim);dispose((void*)mid);dispose((void*)srm);
   }
   const uint8_t *mid=NULL,*otp=NULL;uint32_t mid_len=0,otp_len=0;uint64_t routing=0;
   if(code>=0){begin();put64((uint64_t)-2);pointer(&routing);code=invoke(0x85fe63b0);}
   if(code>=0){begin();put64((uint64_t)-2);pointer(&mid);pointer(&mid_len);pointer(&otp);pointer(&otp_len);code=invoke(0xcfe0b46a);}
   char *mid_string=code<0?NULL:encode(mid,mid_len);char *otp_string=code<0?NULL:encode(otp,otp_len);
   if(mid_string&&otp_string)printf("{\"status\":%ld,\"X-Apple-I-MD-M\":\"%s\",\"X-Apple-I-MD\":\"%s\",\"X-Apple-I-MD-RINFO\":\"%llu\"}\n",(long)code,mid_string,otp_string,(unsigned long long)routing);
   else status(code<0?code:-45001);
   dispose((void*)mid);dispose((void*)otp);free(mid_string);free(otp_string);
  } else {status(-45001);}
  fflush(stdout);
 }
 free(line);begin();invoke(0x08c0fe9e);FreeLibrary(module);return 0;
}
