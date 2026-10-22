#ifndef SPOTIFAST_CORE_H
#define SPOTIFAST_CORE_H
#include <stdbool.h>
#include <stddef.h>
typedef struct Engine SFEngine;
typedef void (*SFNotify)(void *context);
// Context lives until sf_destroy returns. Notification may run on any thread.
SFEngine *sf_create(SFNotify callback, void *context);
// Host serializes commands, snapshot reads, credential reads and destruction.
bool sf_command(SFEngine *engine, const char *json);
// Strings are UTF-8. Release each non-null result with sf_string_free.
char *sf_snapshot(const SFEngine *engine);
// Sensitive: send only to Keychain, never logs, preferences, or ordinary files.
char *sf_credentials(const SFEngine *engine);
char *sf_eq_presets(void);
// Real OS/version used by librespot for client-token requests. No credentials.
char *sf_platform_info(void);
char *sf_parse_link(const char *value);
// Validate an existing invite only. Returns {url, shortened} JSON or NULL.
// value points to length valid UTF-8 bytes. No network, session or Jam creation.
char *sf_parse_jam_invite(const char *value, size_t length);
// One render consumer, disjoint planar stereo float buffers, 44100 Hz.
// No locks, allocation, waits or network I/O. At most 65536 frames per call.
void sf_render(const SFEngine *engine, float *left, float *right, size_t frames);
void sf_string_free(char *value);
// Stop and detach AVAudioEngine before destroying. May wait up to five seconds.
void sf_destroy(SFEngine *engine);
#endif
