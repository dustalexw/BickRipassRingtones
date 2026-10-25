#include "DeviceBridge.h"
#include <dlfcn.h>
#include <pthread.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>

typedef void *Ref;
static void *library;
static pthread_mutex_t loader=PTHREAD_MUTEX_INITIALIZER;
static int (*device_list)(char***,int*),(*list_free)(char**),(*device_new)(Ref*,const char*),(*device_free)(Ref);
static int (*lockdown_new)(Ref,Ref*,const char*),(*lockdown_free)(Ref),(*get_value)(Ref,const char*,const char*,Ref*);
static void (*plist_string)(Ref,char**),(*plist_free_node)(Ref);
static int (*afc_start)(Ref,Ref*,const char*),(*afc_free)(Ref),(*file_open)(Ref,const char*,int,uint64_t*),(*file_close)(Ref,uint64_t),(*file_read)(Ref,uint64_t,char*,uint32_t,uint32_t*),(*file_write)(Ref,uint64_t,const char*,uint32_t,uint32_t*),(*path_rename)(Ref,const char*,const char*),(*path_remove)(Ref,const char*),(*path_mkdir)(Ref,const char*);
static void message(char **error,const char *text,int code){if(error){char buffer[512];snprintf(buffer,sizeof(buffer),"%s (code %d)",text,code);*error=strdup(buffer);}}
static int load(char **error){
 pthread_mutex_lock(&loader);
 if(library){pthread_mutex_unlock(&loader);return 0;}
 const char *paths[]={"/opt/homebrew/lib/libimobiledevice-1.0.dylib","/usr/local/lib/libimobiledevice-1.0.dylib","/opt/homebrew/opt/libimobiledevice/lib/libimobiledevice-1.0.dylib","/usr/local/opt/libimobiledevice/lib/libimobiledevice-1.0.dylib",NULL};
 for(int i=0;paths[i];i++){library=dlopen(paths[i],RTLD_NOW|RTLD_LOCAL);if(library)break;}
 if(!library){pthread_mutex_unlock(&loader);message(error,"USB transfer needs libimobiledevice. Install it with: brew install libimobiledevice",-200);return -200;}
 #define SYMBOL(variable,name) do { *(void **)(&variable)=dlsym(library,name); if(!variable){dlclose(library);library=NULL;pthread_mutex_unlock(&loader);message(error,"The installed libimobiledevice is missing a required interface. Update it with Homebrew",-201);return -201;} } while(0)
 SYMBOL(device_list,"idevice_get_device_list");SYMBOL(list_free,"idevice_device_list_free");SYMBOL(device_new,"idevice_new");SYMBOL(device_free,"idevice_free");
 SYMBOL(lockdown_new,"lockdownd_client_new_with_handshake");SYMBOL(lockdown_free,"lockdownd_client_free");SYMBOL(get_value,"lockdownd_get_value");SYMBOL(plist_string,"plist_get_string_val");SYMBOL(plist_free_node,"plist_free");
 SYMBOL(afc_start,"afc_client_start_service");SYMBOL(afc_free,"afc_client_free");SYMBOL(file_open,"afc_file_open");SYMBOL(file_close,"afc_file_close");SYMBOL(file_read,"afc_file_read");SYMBOL(file_write,"afc_file_write");SYMBOL(path_rename,"afc_rename_path");SYMBOL(path_remove,"afc_remove_path");SYMBOL(path_mkdir,"afc_make_directory");
 #undef SYMBOL
 pthread_mutex_unlock(&loader);return 0;
}
void br_free(void *data){free(data);}
void br_free_devices(char **ids,int count){if(ids){for(int i=0;i<count;i++)free(ids[i]);free(ids);}}
int br_devices(char ***ids,int *count,char **error){
 *ids=NULL;*count=0;int status=load(error);if(status)return status;
 char **raw=NULL;int n=0;status=device_list(&raw,&n);
 if(status){message(error,"Could not list USB iPhones. Check the cable and unlock the phone",status);return status;}
 char **copy=calloc((size_t)n+1,sizeof(char*));if(!copy){list_free(raw);return -202;}
 for(int i=0;i<n;i++){copy[i]=strdup(raw[i]);if(!copy[i]){br_free_devices(copy,i);list_free(raw);return -202;}}
 list_free(raw);*ids=copy;*count=n;return 0;
}
typedef struct{Ref device;Ref afc;char *version;} Session;
void br_disconnect(void *opaque){Session *s=opaque;if(!s)return;if(s->afc)afc_free(s->afc);if(s->device)device_free(s->device);free(s->version);free(s);}
const char *br_ios_version(void *session){return session ? ((Session*)session)->version:NULL;}
void *br_connect(const char *udid,char **name,char **error){
 *name=NULL;if(load(error))return NULL;
 Session *s=calloc(1,sizeof(Session));if(!s)return NULL;
 int status=device_new(&s->device,udid);if(status){message(error,"The selected USB iPhone disconnected",status);br_disconnect(s);return NULL;}
 Ref client=NULL;status=lockdown_new(s->device,&client,"BickRipassRingtones");
 if(status){message(error,"Unlock your iPhone and choose Trust This Computer on the phone, then try again",status);br_disconnect(s);return NULL;}
 Ref product=NULL;char *kind=NULL;
 if(get_value(client,NULL,"ProductType",&product)==0 && product){plist_string(product,&kind);plist_free_node(product);}
 if(kind && strncmp(kind,"iPhone",6)!=0){free(kind);lockdown_free(client);br_disconnect(s);message(error,"Select an iPhone for ringtone transfer",-205);return NULL;}free(kind);
 Ref value=NULL;if(get_value(client,NULL,"DeviceName",&value)==0 && value){plist_string(value,name);plist_free_node(value);}
 Ref version=NULL;if(get_value(client,NULL,"ProductVersion",&version)==0 && version){plist_string(version,&s->version);plist_free_node(version);}
 lockdown_free(client);
 status=afc_start(s->device,&s->afc,"BickRipassRingtones");
 if(status){message(error,"iPhone media access was refused. Unlock and trust this Mac, then reconnect",status);br_disconnect(s);if(*name){free(*name);*name=NULL;}return NULL;}
 return s;
}
int br_read(void *opaque,const char *path,uint8_t **bytes,size_t *length,char **error){
 Session *s=opaque;*bytes=NULL;*length=0;uint64_t handle=0;
 int status=file_open(s->afc,path,1,&handle);if(status==8)return 8;if(status){message(error,"Could not read the iPhone media file",status);return status;}
 size_t capacity=65536,used=0;uint8_t *result=malloc(capacity);if(!result){file_close(s->afc,handle);return -202;}
 for(;;){
  if(capacity-used<65536){if(capacity>=64*1024*1024){status=-203;break;}size_t next=capacity*2;void *larger=realloc(result,next);if(!larger){status=-202;break;}result=larger;capacity=next;}
  uint32_t received=0;status=file_read(s->afc,handle,(char*)result+used,65536,&received);
  if(status==14){status=0;break;}if(status)break;used+=received;if(!received)break;
 }
 int closed=file_close(s->afc,handle);if(!status)status=closed;
 if(status){free(result);message(error,"Reading the iPhone media file failed",status);return status;}
 *bytes=result;*length=used;return 0;
}
int br_write(void *opaque,const char *path,const uint8_t *bytes,size_t length,char **error){
 Session *s=opaque;uint64_t handle=0;int status=file_open(s->afc,path,3,&handle);if(status){message(error,"The iPhone refused the upload",status);return status;}
 size_t sent=0;while(sent<length){uint32_t n=(uint32_t)((length-sent)>65536?65536:(length-sent)),written=0;status=file_write(s->afc,handle,(const char*)bytes+sent,n,&written);if(status||!written){if(!status)status=-204;break;}sent+=written;}
 int closed=file_close(s->afc,handle);if(!status)status=closed;
 if(status)message(error,"The iPhone upload did not finish",status);return status;
}
int br_rename(void *opaque,const char *source,const char *destination,char **error){int status=path_rename(((Session*)opaque)->afc,source,destination);if(status)message(error,"The iPhone could not commit the uploaded file",status);return status;}
int br_remove(void *opaque,const char *path,char **error){int status=path_remove(((Session*)opaque)->afc,path);if(status && status!=8)message(error,"An unfinished upload could not be removed",status);return status==8?0:status;}
int br_mkdir(void *opaque,const char *path,char **error){int status=path_mkdir(((Session*)opaque)->afc,path);if(status && status!=16)message(error,"The iPhone media folder is not writable",status);return status==16?0:status;}
