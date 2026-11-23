// Development-fixture executable only. It reads no files or environment values.
// Chrome supplies the extension origin and owns both framing pipes/process life.
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static int read_exact(void* output, size_t size) {
  unsigned char* cursor = output;
  const size_t original = size;
  while (size) {
    const ssize_t count = read(STDIN_FILENO, cursor, size);
    if (count == 0) return size == original ? 0 : -1;
    if (count < 0) { if (errno == EINTR) continue; return -1; }
    cursor += count; size -= (size_t)count;
  }
  return 1;
}
static int write_exact(const void* input, size_t size) {
  const unsigned char* cursor = input;
  while (size) {
    const ssize_t count = write(STDOUT_FILENO, cursor, size);
    if (count < 0) { if (errno == EINTR) continue; return 0; }
    if (!count) return 0;
    cursor += count; size -= (size_t)count;
  }
  return 1;
}
static int valid_origin(const char* value) {
  static const char prefix[] = "chrome-extension://";
  if (strlen(value) != sizeof(prefix)-1+32+1 ||
      strncmp(value,prefix,sizeof(prefix)-1) || value[strlen(value)-1] != '/') return 0;
  for (unsigned i=sizeof(prefix)-1;i<sizeof(prefix)-1+32;++i)
    if (value[i]<'a' || value[i]>'p') return 0;
  return 1;
}
int main(int argc, char** argv) {
  if (argc != 2 || !valid_origin(argv[1])) return 2;
  for (;;) {
    uint32_t size = 0;
    const int header = read_exact(&size, sizeof(size));
    if (!header) return 0;
    if (header < 0 || size == 0 || size > 4096) return 3;
    char request[4097] = {0};
    if (read_exact(request,size) != 1) return 3;
    static const char expected[] = "{\"kind\":\"arx-native-fixture\"}";
    if (size != sizeof(expected)-1 || memcmp(request,expected,size)) return 4;
    char response[256];
    const int count = snprintf(response,sizeof(response),
        "{\"kind\":\"arx-native-fixture\",\"pid\":%ld,\"origin\":\"%s\",\"framed\":true}",
        (long)getpid(),argv[1]);
    if (count <= 0 || (size_t)count >= sizeof(response)) return 5;
    size = (uint32_t)count;
    if (!write_exact(&size,sizeof(size)) || !write_exact(response,size)) return 5;
  }
}
