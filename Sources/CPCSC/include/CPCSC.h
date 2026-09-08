#ifndef CPCSC_SHIM_H
#define CPCSC_SHIM_H

#include <stdint.h>
#include <stddef.h>

/*
 * Isolated C wrapper over macOS PCSC.framework.
 *
 * Why this exists: PCSC.framework's module map declares `requires !swift`, so Swift cannot
 * import it — directly or transitively through a header that includes <PCSC/winscard.h>.
 * Including the PCSC headers only inside shim.c keeps the incompatible module entirely out
 * of Swift's view while still linking against the real framework.
 *
 * All handles are passed as opaque void* to avoid leaking PCSC typedefs into this header.
 * All functions return the raw PC/SC LONG status widened to int32_t; 0 == SCARD_S_SUCCESS.
 */

/* Context lifecycle */
int32_t k2_establish(void **ctx);
int32_t k2_release(void *ctx);
int32_t k2_is_valid(void *ctx);

/* Reader enumeration. Call once with buf==NULL to size, then again with a buffer.
   Result is a multi-string: NUL-separated names terminated by a double NUL. */
int32_t k2_list_readers(void *ctx, char *buf, uint32_t *len);

/* Card session. `direct` requests SCARD_SHARE_DIRECT (unsupported on macOS — see D-005). */
int32_t k2_connect(void *ctx, const char *reader, int direct, void **card, uint32_t *proto);
int32_t k2_reconnect(void *card, uint32_t *proto);
int32_t k2_disconnect(void *card);

/* APDU exchange */
int32_t k2_transmit(void *card, uint32_t proto,
                    const uint8_t *tx, uint32_t txlen,
                    uint8_t *rx, uint32_t *rxlen);

/* Reader escape / control codes */
int32_t k2_control(void *card, uint32_t code,
                   const uint8_t *tx, uint32_t txlen,
                   uint8_t *rx, uint32_t rxlen, uint32_t *out);
uint32_t k2_ioctl_escape(void);

/* Card status: ATR, state and active protocol */
int32_t k2_atr(void *card, uint8_t *atr, uint32_t *atrlen, uint32_t *state, uint32_t *proto);

/* Blocking wait for reader/card state change. timeoutMs may be K2_INFINITE. */
int32_t k2_status_change(void *ctx, const char *reader,
                         uint32_t curState, uint32_t *newState, uint32_t timeoutMs);

/* Cancel a pending k2_status_change on another thread. */
int32_t k2_cancel(void *ctx);

/* Selected SCARD_STATE_* / status constants, re-exported so Swift need not hardcode them. */
uint32_t k2_state_unaware(void);
uint32_t k2_state_ignore(void);
uint32_t k2_state_changed(void);
uint32_t k2_state_unknown(void);
uint32_t k2_state_unavailable(void);
uint32_t k2_state_empty(void);
uint32_t k2_state_present(void);
uint32_t k2_state_mute(void);
uint32_t k2_infinite(void);

/* Human-readable message for a PC/SC status code. */
const char *k2_error_string(int32_t rv);

#endif /* CPCSC_SHIM_H */
