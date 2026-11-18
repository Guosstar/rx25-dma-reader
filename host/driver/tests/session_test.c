#include <Windows.h>
#include <winioctl.h>
#include <stdio.h>
#include <string.h>
#include "../rx25_session.h"

static unsigned tests;
#define CHECK(c) do { tests++; if (!(c)) { printf("FAIL session line %u: %s\n",__LINE__,#c); return 1; } } while(0)
static RX25_SESSION fresh(void)
{
    RX25_SESSION s={0};
    RX25_SESSION_TOKEN t={11,22,33};
    (void)Rx25SessionOpen(&s,t,44,0x12345678000ULL,8192,0x10F);
    return s;
}
static RX25_SESSION_MESSAGE message(void)
{
    RX25_SESSION_MESSAGE m={{11,22,33},1,0x10203040,0x1234,0,16};
    return m;
}
static unsigned vector_count;
static void trace(FILE *file, RX25_SESSION *s, ULONG open, ULONG command,
    RX25_SESSION_MESSAGE m, ULONGLONG configSession, ULONG caps)
{
    RX25_SESSION_TOKEN token={11,22,configSession};
    RX25_SESSION empty={0};
    enum RX25_SESSION_RESULT result;
    ULONG dispatch=0;
    if(open==2) { *s=empty;result=Rx25SessionRejected; }
    else if(open) result=Rx25SessionOpen(s,token,44,0x12345678000ULL,8192,caps) ? Rx25SessionAccepted : Rx25SessionRejected;
    else {
        result=Rx25SessionApply(s,(enum RX25_SESSION_COMMAND)command,&m);
        dispatch=command==Rx25SessionSubmit && result==Rx25SessionAccepted;
    }
    fprintf(file,"%016llx %016llx %016llx %016llx %016llx %016llx %016llx %016llx ",
        (ULONGLONG)open,(ULONGLONG)command,11ULL,22ULL,configSession,44ULL,0x12345678000ULL,8192ULL);
    fprintf(file,"%016llx %016llx %016llx %016llx %016llx %016llx %016llx %016llx ",
        (ULONGLONG)caps,m.Token.LocalEpoch,m.Token.PeerEpoch,m.Token.SessionId,m.Sequence,
        (ULONGLONG)m.RequestId,(ULONGLONG)m.Generation,(ULONGLONG)m.TargetOffset);
    fprintf(file,"%016llx %016llx %016llx %016llx %016llx %016llx %016llx %016llx\n",
        (ULONGLONG)m.Length,(ULONGLONG)result,(ULONGLONG)s->State,
        (ULONGLONG)Rx25SessionCanClose(s),(ULONGLONG)s->Active,s->DataAddress,s->CqAddress,(ULONGLONG)dispatch);
    vector_count++;
}
int main(int argc,char **argv)
{
    RX25_SESSION s=fresh(),saved;
    RX25_SESSION_MESSAGE m=message(),wrong;
    RX25_SESSION_TOKEN token={11,22,33};
    unsigned n,step;
    CHECK(s.State==Rx25SessionReady && !Rx25SessionCanClose(&s));
    CHECK(!Rx25SessionOpen(&s,token,44,0x12345678000ULL,8192,0x10F));
    s.State=Rx25SessionClosed;
    CHECK(!Rx25SessionOpen(&s,token,44,0x12345678000ULL,8192,0x30F));
    CHECK(!Rx25SessionOpen(&s,token,44,0xFFFFFFFFFFFFF000ULL,8192,0x10F));
    CHECK(!Rx25SessionOpen(&s,token,44,0x12345678010ULL,8192,0x10F));
    CHECK(!Rx25SessionOpen(&s,token,0,0x12345678000ULL,8192,0x10F));
    CHECK(!Rx25SessionOpen(&s,token,44,0x12345678000ULL,4096,0x10F));
    token.PeerEpoch=0;CHECK(!Rx25SessionOpen(&s,token,44,0x12345678000ULL,8192,0x10F));
    s=fresh();saved=s;
    wrong=m;wrong.Token.LocalEpoch++;CHECK(Rx25SessionApply(&s,Rx25SessionSubmit,&wrong)==Rx25SessionStale);
    wrong=m;wrong.Token.PeerEpoch++;CHECK(Rx25SessionApply(&s,Rx25SessionSubmit,&wrong)==Rx25SessionStale);
    wrong=m;wrong.Token.SessionId++;CHECK(Rx25SessionApply(&s,Rx25SessionFail,&wrong)==Rx25SessionStale);
    CHECK(!memcmp(&s,&saved,sizeof(s)));
#define BAD(field,value) do { s=fresh();saved=s;wrong=m;wrong.field=value; \
    CHECK(Rx25SessionApply(&s,Rx25SessionSubmit,&wrong)==Rx25SessionRejected);CHECK(!memcmp(&s,&saved,sizeof(s))); } while(0)
    BAD(Sequence,0);BAD(Sequence,2);BAD(RequestId,0);BAD(Generation,0);BAD(Generation,65536);
    BAD(Length,32);BAD(TargetOffset,1);BAD(TargetOffset,4096);BAD(TargetOffset,4080);
    BAD(TargetOffset,0xFFFFFFF0u);
    s=fresh();m.Length=128;m.TargetOffset=3968;
    CHECK(Rx25SessionApply(&s,Rx25SessionSubmit,&m)==Rx25SessionAccepted);
    CHECK(s.DataAddress==0x12345678F80ULL && s.CqAddress==0x12345679F80ULL);
    CHECK(Rx25SessionApply(&s,Rx25SessionSubmit,&m)==Rx25SessionRejected);
    wrong=m;wrong.RequestId++;CHECK(Rx25SessionApply(&s,Rx25SessionComplete,&wrong)==Rx25SessionStale);
    wrong=m;wrong.Generation++;CHECK(Rx25SessionApply(&s,Rx25SessionComplete,&wrong)==Rx25SessionStale);
    wrong=m;wrong.Length=16;CHECK(Rx25SessionApply(&s,Rx25SessionComplete,&wrong)==Rx25SessionStale);
    CHECK(Rx25SessionApply(&s,Rx25SessionComplete,&m)==Rx25SessionAccepted);
    CHECK(!Rx25SessionCanClose(&s));
    CHECK(Rx25SessionApply(&s,Rx25SessionSubmit,&m)==Rx25SessionRejected);
    m.Sequence=2;CHECK(Rx25SessionApply(&s,Rx25SessionSubmit,&m)==Rx25SessionAccepted);
    wrong=m;wrong.Sequence=99;
    CHECK(Rx25SessionApply(&s,Rx25SessionStop,&wrong)==Rx25SessionAccepted);
    CHECK(Rx25SessionApply(&s,Rx25SessionPeerStopped,&wrong)==Rx25SessionRejected);
    CHECK(Rx25SessionApply(&s,Rx25SessionSubmit,&m)==Rx25SessionRejected);
    CHECK(Rx25SessionApply(&s,Rx25SessionComplete,&m)==Rx25SessionAccepted);
    CHECK(s.State==Rx25SessionStopping && !Rx25SessionCanClose(&s));
    CHECK(Rx25SessionApply(&s,Rx25SessionLocalFenced,&wrong)==Rx25SessionRejected);
    CHECK(Rx25SessionApply(&s,Rx25SessionStop,&wrong)==Rx25SessionAccepted);
    wrong.Sequence=98;CHECK(Rx25SessionApply(&s,Rx25SessionStop,&wrong)==Rx25SessionStale);
    CHECK(Rx25SessionApply(&s,Rx25SessionPeerStopped,&wrong)==Rx25SessionRejected);
    wrong.Sequence=99;
    CHECK(Rx25SessionApply(&s,Rx25SessionPeerStopped,&wrong)==Rx25SessionAccepted);
    CHECK(!Rx25SessionCanClose(&s));
    CHECK(Rx25SessionApply(&s,Rx25SessionLocalFenced,&wrong)==Rx25SessionAccepted);
    CHECK(Rx25SessionCanClose(&s));
    CHECK(Rx25SessionApply(&s,Rx25SessionClose,&wrong)==Rx25SessionAccepted);
    CHECK(!Rx25SessionCanClose(&s));
    token=message().Token;
    CHECK(!Rx25SessionOpen(&s,token,44,0x12345678000ULL,8192,0x10F));
    token.SessionId++;
    CHECK(Rx25SessionOpen(&s,token,44,0x12345678000ULL,8192,0x10F));
    wrong.Token=token;wrong.Sequence=1;
    CHECK(Rx25SessionApply(&s,Rx25SessionStop,&wrong)==Rx25SessionAccepted);
    CHECK(Rx25SessionCanClose(&s) && !s.EverArmed);
    s=fresh();s.LastSequence=~(ULONGLONG)0;m=message();
    CHECK(Rx25SessionApply(&s,Rx25SessionSubmit,&m)==Rx25SessionRejected);
    s=fresh();CHECK(Rx25SessionApply(&s,Rx25SessionSubmit,&m)==Rx25SessionAccepted);
    CHECK(Rx25SessionApply(&s,Rx25SessionFail,&m)==Rx25SessionIsolated);
    for(n=1;n<=7;n++) CHECK(Rx25SessionApply(&s,(enum RX25_SESSION_COMMAND)n,&m)==Rx25SessionIsolated);
    CHECK(!Rx25SessionCanClose(&s));
    /* All 7^6 command histories after a real submit: no completion/STOP alone
     * can grant close; FAULT is absorbing, and rejected events do not mutate. */
    for(n=0;n<117649;n++) {
        unsigned code=n;
        s=fresh();m=message();
        CHECK(Rx25SessionApply(&s,Rx25SessionSubmit,&m)==Rx25SessionAccepted);
        for(step=0;step<6;step++) {
            enum RX25_SESSION_COMMAND command=(enum RX25_SESSION_COMMAND)(code%7+1);
            enum RX25_SESSION_RESULT result;
            code/=7;saved=s;
            result=Rx25SessionApply(&s,command,&m);
            if(result==Rx25SessionRejected || result==Rx25SessionStale) CHECK(!memcmp(&s,&saved,sizeof(s)));
            if(saved.State==Rx25SessionFault) CHECK(s.State==Rx25SessionFault);
            if(Rx25SessionCanClose(&s)) CHECK(s.PeerStopped && s.LocalFenced && !s.Active && s.EverArmed);
            if(s.State==Rx25SessionClosed && saved.State!=Rx25SessionClosed) CHECK(Rx25SessionCanClose(&saved));
        }
    }
    if(argc==2) {
        FILE *file=NULL;
        unsigned seed=0x251112;
        static const ULONG commands[]={1,1,2,1,3,1,5,4,2,5,4,3,5,6};
        if(fopen_s(&file,argv[1],"w")) return 1;
        fprintf(file,"%016llx\n",0ULL);
        s=fresh();m=message();
        trace(file,&s,2,0,m,33,0x10F);
        trace(file,&s,1,0,m,33,0x30F);
        trace(file,&s,1,0,m,33,0x10F);
        for(n=0;n<sizeof(commands)/sizeof(commands[0]);n++) {
            m.Sequence=commands[n]==1 ? s.LastSequence+1 :
                (commands[n]==2 ? s.LastSequence : 99);
            trace(file,&s,0,commands[n],m,33,0x10F);
        }
        trace(file,&s,1,0,m,33,0x10F); /* Cannot reuse closed token. */
        for(n=0;n<128;n++) {
            ULONGLONG session=1000ULL+n;
            m=message();m.Token.SessionId=session;
            trace(file,&s,2,0,m,session,0x10F);
            trace(file,&s,1,0,m,session,0x10F);
            trace(file,&s,0,1,m,session,0x10F);
            for(step=0;step<32;step++) {
                ULONG command;
                seed=seed*1664525u+1013904223u;command=(seed>>16)%7+1;
                m=message();m.Token.SessionId=session;
                m.Sequence=command==1 ? s.LastSequence+1 :
                    (command==2 ? s.LastSequence : (s.StopSequence ? s.StopSequence : 99));
                m.Length=(n&1) ? 128 : 16;m.TargetOffset=(n&1) ? 3968 : 0;
                if((seed&7)==0) m.Token.PeerEpoch++;
                if((seed&15)==1) m.TargetOffset=4096;
                if((seed&15)==2) m.Generation++;
                trace(file,&s,0,command,m,session,0x10F);
            }
        }
        if(fseek(file,0,SEEK_SET)) return 1;
        fprintf(file,"%016llx\n",(ULONGLONG)vector_count);
        if(fclose(file)) return 1;
    }
    printf("PASS %u session assertions; histories=117649; vectors=%u; no hardware I/O\n",tests,vector_count);
    return 0;
}
