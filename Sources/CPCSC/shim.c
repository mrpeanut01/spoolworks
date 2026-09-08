#include <PCSC/wintypes.h>
#include <PCSC/pcsclite.h>
#include <PCSC/winscard.h>

#include "include/CPCSC.h"

#include <string.h>
#include <stdio.h>

/* macOS's pcsclite headers omit SCARD_CTL_CODE, which is present on Windows and on
   Linux's pcsc-lite. The value layout is the pcsc-lite convention. */
#ifndef SCARD_CTL_CODE
#define SCARD_CTL_CODE(code) (0x42000000 + (code))
#endif

/* PCSC handles are integer types; round-trip them through uintptr_t so the Swift side
   can treat them as opaque pointers without caring about the underlying width. */
#define TO_CTX(p)  ((SCARDCONTEXT)(uintptr_t)(p))
#define TO_CARD(p) ((SCARDHANDLE)(uintptr_t)(p))

/* Out-parameters are dereferenced unconditionally below, so a NULL one is a segfault rather
   than a status code. Every caller in this repository passes valid pointers, but this is a
   C boundary: the check costs nothing and turns a crash into an error Swift can report. */
#define SW_REQUIRE(cond) do { if (!(cond)) return (int32_t)SCARD_E_INVALID_PARAMETER; } while (0)

int32_t k2_establish(void **ctx) {
    SW_REQUIRE(ctx);
    SCARDCONTEXT c = 0;
    LONG rv = SCardEstablishContext(SCARD_SCOPE_SYSTEM, NULL, NULL, &c);
    *ctx = (void *)(uintptr_t)c;
    return (int32_t)rv;
}

int32_t k2_release(void *ctx) {
    return (int32_t)SCardReleaseContext(TO_CTX(ctx));
}

int32_t k2_is_valid(void *ctx) {
    return (int32_t)SCardIsValidContext(TO_CTX(ctx));
}

int32_t k2_list_readers(void *ctx, char *buf, uint32_t *len) {
    SW_REQUIRE(len);
    DWORD l = *len;
    LONG rv = SCardListReaders(TO_CTX(ctx), NULL, buf, &l);
    *len = (uint32_t)l;
    return (int32_t)rv;
}

int32_t k2_connect(void *ctx, const char *reader, int direct, void **card, uint32_t *proto) {
    SW_REQUIRE(reader && card && proto);
    SCARDHANDLE h = 0;
    DWORD p = 0;
    /* SCARD_SHARE_DIRECT is not supported by macOS's PC/SC stack (returns
       SCARD_E_UNSUPPORTED_FEATURE). Callers should treat direct mode as best-effort. */
    LONG rv = SCardConnect(TO_CTX(ctx), reader,
                           direct ? SCARD_SHARE_DIRECT : SCARD_SHARE_SHARED,
                           direct ? 0 : (SCARD_PROTOCOL_T0 | SCARD_PROTOCOL_T1),
                           &h, &p);
    *card = (void *)(uintptr_t)h;
    *proto = (uint32_t)p;
    return (int32_t)rv;
}

int32_t k2_reconnect(void *card, uint32_t *proto) {
    SW_REQUIRE(proto);
    DWORD p = 0;
    LONG rv = SCardReconnect(TO_CARD(card), SCARD_SHARE_SHARED,
                             SCARD_PROTOCOL_T0 | SCARD_PROTOCOL_T1,
                             SCARD_RESET_CARD, &p);
    *proto = (uint32_t)p;
    return (int32_t)rv;
}

int32_t k2_disconnect(void *card) {
    return (int32_t)SCardDisconnect(TO_CARD(card), SCARD_LEAVE_CARD);
}

int32_t k2_transmit(void *card, uint32_t proto,
                    const uint8_t *tx, uint32_t txlen,
                    uint8_t *rx, uint32_t *rxlen) {
    SW_REQUIRE(tx && rx && rxlen);
    SCARD_IO_REQUEST pci;
    pci.dwProtocol = proto;
    pci.cbPciLength = sizeof(SCARD_IO_REQUEST);
    DWORD rl = *rxlen;
    LONG rv = SCardTransmit(TO_CARD(card), &pci, tx, txlen, NULL, rx, &rl);
    *rxlen = (uint32_t)rl;
    return (int32_t)rv;
}

int32_t k2_control(void *card, uint32_t code,
                   const uint8_t *tx, uint32_t txlen,
                   uint8_t *rx, uint32_t rxlen, uint32_t *out) {
    SW_REQUIRE(out);
    DWORD o = 0;
    LONG rv = SCardControl(TO_CARD(card), code, tx, txlen, rx, rxlen, &o);
    *out = (uint32_t)o;
    return (int32_t)rv;
}

uint32_t k2_ioctl_escape(void) {
    return (uint32_t)SCARD_CTL_CODE(3500);
}

int32_t k2_atr(void *card, uint8_t *atr, uint32_t *atrlen, uint32_t *state, uint32_t *proto) {
    SW_REQUIRE(atr && atrlen && state && proto);
    DWORD al = *atrlen, st = 0, pr = 0, namelen = 0;
    LONG rv = SCardStatus(TO_CARD(card), NULL, &namelen, &st, &pr, atr, &al);
    *atrlen = (uint32_t)al;
    *state = (uint32_t)st;
    *proto = (uint32_t)pr;
    return (int32_t)rv;
}

int32_t k2_status_change(void *ctx, const char *reader,
                         uint32_t curState, uint32_t *newState, uint32_t timeoutMs) {
    SW_REQUIRE(reader && newState);
    SCARD_READERSTATE st;
    memset(&st, 0, sizeof(st));
    st.szReader = reader;
    st.dwCurrentState = curState;
    LONG rv = SCardGetStatusChange(TO_CTX(ctx), timeoutMs, &st, 1);
    *newState = (uint32_t)st.dwEventState;
    return (int32_t)rv;
}

int32_t k2_cancel(void *ctx) {
    return (int32_t)SCardCancel(TO_CTX(ctx));
}

uint32_t k2_state_unaware(void)     { return (uint32_t)SCARD_STATE_UNAWARE; }
uint32_t k2_state_ignore(void)      { return (uint32_t)SCARD_STATE_IGNORE; }
uint32_t k2_state_changed(void)     { return (uint32_t)SCARD_STATE_CHANGED; }
uint32_t k2_state_unknown(void)     { return (uint32_t)SCARD_STATE_UNKNOWN; }
uint32_t k2_state_unavailable(void) { return (uint32_t)SCARD_STATE_UNAVAILABLE; }
uint32_t k2_state_empty(void)       { return (uint32_t)SCARD_STATE_EMPTY; }
uint32_t k2_state_present(void)     { return (uint32_t)SCARD_STATE_PRESENT; }
uint32_t k2_state_mute(void)        { return (uint32_t)SCARD_STATE_MUTE; }
uint32_t k2_infinite(void)          { return (uint32_t)INFINITE; }

const char *k2_error_string(int32_t rv) {
    return pcsc_stringify_error((LONG)rv);
}
