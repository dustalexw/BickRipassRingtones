#ifndef BICK_DEVICE_BRIDGE_H
#define BICK_DEVICE_BRIDGE_H
#include <stdint.h>
#include <stddef.h>
int br_devices(char ***ids,int *count,char **error);
void br_free_devices(char **ids,int count);
void br_free(void *data);
void *br_connect(const char *udid,char **name,char **error);
void br_disconnect(void *session);
const char *br_ios_version(void *session);
int br_read(void *session,const char *path,uint8_t **bytes,size_t *length,char **error);
int br_write(void *session,const char *path,const uint8_t *bytes,size_t length,char **error);
int br_rename(void *session,const char *source,const char *destination,char **error);
int br_remove(void *session,const char *path,char **error);
int br_mkdir(void *session,const char *path,char **error);
#endif
