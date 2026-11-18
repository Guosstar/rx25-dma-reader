#pragma once
#include "rx25dma_public.h"

/* Executable offline contract. No IOCTL exposes this state. Open's mapping and
 * the two drain events must come from trusted kernel/hardware adapters, never
 * from user claims. Current firmware provides neither drain adapter. */
enum RX25_SESSION_STATE { Rx25SessionClosed, Rx25SessionReady,
    Rx25SessionRunning, Rx25SessionStopping, Rx25SessionDrained, Rx25SessionFault };
enum RX25_SESSION_COMMAND { Rx25SessionSubmit=1, Rx25SessionComplete,
    Rx25SessionStop, Rx25SessionPeerStopped, Rx25SessionLocalFenced,
    Rx25SessionClose, Rx25SessionFail };
enum RX25_SESSION_RESULT { Rx25SessionRejected, Rx25SessionAccepted,
    Rx25SessionStale, Rx25SessionIsolated };

typedef struct _RX25_SESSION_TOKEN {
    ULONGLONG LocalEpoch, PeerEpoch, SessionId;
} RX25_SESSION_TOKEN;
typedef struct _RX25_SESSION_MESSAGE {
    RX25_SESSION_TOKEN Token;
    ULONGLONG Sequence;
    ULONG RequestId, Generation, TargetOffset, Length;
} RX25_SESSION_MESSAGE;
typedef struct _RX25_SESSION {
    RX25_SESSION_TOKEN Token;
    ULONGLONG BufferId, DmaAddress, LastSequence, StopSequence;
    ULONGLONG DataAddress, CqAddress;
    ULONG RequestId, Generation, Length;
    enum RX25_SESSION_STATE State;
    ULONG Active, EverArmed, PeerStopped, LocalFenced;
} RX25_SESSION;

static __inline int Rx25SessionMatches(const RX25_SESSION *s, const RX25_SESSION_TOKEN *t)
{
    return t->LocalEpoch==s->Token.LocalEpoch && t->PeerEpoch==s->Token.PeerEpoch &&
           t->SessionId==s->Token.SessionId;
}

/* Caller owns a fresh object and fresh non-reused epochs/session ID. This
 * function must never overwrite an existing live/quarantined allocation. */
static __inline int Rx25SessionOpen(RX25_SESSION *s, RX25_SESSION_TOKEN token,
    ULONGLONG bufferId, ULONGLONG dmaAddress, ULONG bufferBytes, ULONG peerCaps)
{
    RX25_SESSION empty = {0};
    if (s->State!=Rx25SessionClosed || !token.LocalEpoch || !token.PeerEpoch ||
        !token.SessionId || !bufferId || bufferBytes!=RX25_DMA_BYTES ||
        peerCaps!=0x10F || (s->Token.SessionId && Rx25SessionMatches(s,&token)) || (dmaAddress & 4095) ||
        dmaAddress>(~(ULONGLONG)0)-RX25_DMA_BYTES) return 0;
    *s=empty;
    s->Token=token; s->BufferId=bufferId; s->DmaAddress=dmaAddress;
    s->State=Rx25SessionReady;
    return 1;
}

static __inline int Rx25SessionCanClose(const RX25_SESSION *s)
{
    return s->State==Rx25SessionDrained && !s->Active &&
        ((!s->EverArmed) || (s->PeerStopped && s->LocalFenced));
}

static __inline enum RX25_SESSION_RESULT Rx25SessionApply(RX25_SESSION *s,
    enum RX25_SESSION_COMMAND command, const RX25_SESSION_MESSAGE *m)
{
    const ULONGLONG maximum=~(ULONGLONG)0;
    if (s->State==Rx25SessionClosed) return Rx25SessionRejected;
    if (!Rx25SessionMatches(s,&m->Token)) return Rx25SessionStale;
    if (s->State==Rx25SessionFault) return Rx25SessionIsolated;
    if (command==Rx25SessionFail) {
        s->State=Rx25SessionFault; return Rx25SessionIsolated;
    }
    switch (command) {
    case Rx25SessionSubmit:
        if (s->State!=Rx25SessionReady || s->Active || s->LastSequence==maximum ||
            m->Sequence!=s->LastSequence+1 || !m->RequestId ||
            !m->Generation || m->Generation>65535 ||
            (m->Length!=16 && m->Length!=128) || (m->TargetOffset & 15) ||
            !Rx25DmaValidRange(4096,m->TargetOffset,m->Length) ||
            !Rx25DmaValidRange(8192,4096+m->TargetOffset,32)) return Rx25SessionRejected;
        s->LastSequence=m->Sequence; s->RequestId=m->RequestId;
        s->Generation=m->Generation; s->Length=m->Length;
        s->DataAddress=s->DmaAddress+m->TargetOffset;
        s->CqAddress=s->DataAddress+4096;
        s->Active=1; s->EverArmed=1; s->State=Rx25SessionRunning;
        return Rx25SessionAccepted;
    case Rx25SessionComplete:
        /* Adapter must first validate published CQ, payload and guards. A
         * completion changes job accounting, never constitutes a drain fence. */
        if (!s->Active || (s->State!=Rx25SessionRunning && s->State!=Rx25SessionStopping) ||
            m->Sequence!=s->LastSequence || m->RequestId!=s->RequestId ||
            m->Generation!=s->Generation || m->Length!=s->Length) return Rx25SessionStale;
        s->Active=0;
        if (s->State==Rx25SessionRunning) s->State=Rx25SessionReady;
        return Rx25SessionAccepted;
    case Rx25SessionStop:
        if (!m->Sequence) return Rx25SessionRejected;
        if (s->State==Rx25SessionStopping || s->State==Rx25SessionDrained)
            return m->Sequence==s->StopSequence ? Rx25SessionAccepted : Rx25SessionStale;
        if (s->State!=Rx25SessionReady && s->State!=Rx25SessionRunning) return Rx25SessionRejected;
        s->StopSequence=m->Sequence; s->PeerStopped=0; s->LocalFenced=0;
        s->State=s->EverArmed ? Rx25SessionStopping : Rx25SessionDrained;
        return Rx25SessionAccepted;
    case Rx25SessionPeerStopped:
        if (s->State!=Rx25SessionStopping || s->Active || m->Sequence!=s->StopSequence)
            return Rx25SessionRejected;
        s->PeerStopped=1; return Rx25SessionAccepted;
    case Rx25SessionLocalFenced:
        if (s->State!=Rx25SessionStopping || s->Active || !s->PeerStopped ||
            m->Sequence!=s->StopSequence) return Rx25SessionRejected;
        s->LocalFenced=1; s->State=Rx25SessionDrained;
        return Rx25SessionAccepted;
    case Rx25SessionClose:
        if (!Rx25SessionCanClose(s) || m->Sequence!=s->StopSequence) return Rx25SessionRejected;
        s->State=Rx25SessionClosed; return Rx25SessionAccepted;
    default: return Rx25SessionRejected;
    }
}
