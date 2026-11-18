#include <Windows.h>
#include <stdio.h>
#include <string.h>
#include "../rx25_cq_v2.h"
static unsigned checks;
#define CHECK(x) do { checks++; if(!(x)) { printf("FAIL cq_v2 line %u\n",__LINE__); return 1; } } while(0)
int main(int argc,char **argv)
{
    RX25_CQ_V2 good={0x12345678,0x10001,128,1,0,1,RX25_CQ_V2_MAGIC,0}, c;
    unsigned field,bit;
    FILE *out=NULL;
    CHECK(sizeof(good)==32);
    CHECK(Rx25CqV2Check(&good,0x10001,0x10001,good.RequestId,1,0x100000001ULL,128)==Rx25CqV2Success);
    CHECK(Rx25CqV2Check(&good,0x10001,0,good.RequestId,1,0x100000001ULL,128)==Rx25CqV2Pending);
    CHECK(Rx25CqV2Check(&good,0,0,good.RequestId,1,0x100000001ULL,128)==Rx25CqV2Pending);
    CHECK(Rx25CqV2Check(&good,0x10001,0x10001,good.RequestId,1,1,128)==Rx25CqV2Stale);
    CHECK(Rx25CqV2Check(&good,0x10001,0x10001,good.RequestId,2,0x100000001ULL,128)==Rx25CqV2Stale);
    CHECK(Rx25CqV2Check(&good,0x10001,0x10001,good.RequestId,0,0x100000001ULL,128)==Rx25CqV2Invalid);
    CHECK(Rx25CqV2Check(&good,0x10001,0x10001,good.RequestId,65536,0x100000001ULL,128)==Rx25CqV2Invalid);
    CHECK(Rx25CqV2Check(&good,0x10001,0x10001,0,1,0x100000001ULL,128)==Rx25CqV2Invalid);
    CHECK(Rx25CqV2Check(&good,0x10001,0x10001,good.RequestId,1,0,128)==Rx25CqV2Invalid);
    CHECK(Rx25CqV2Check(&good,0x10001,0x10001,good.RequestId,1,0x100000001ULL,32)==Rx25CqV2Invalid);
    /* Every single-bit mutation in the 32-byte record must lose success. */
    for(field=0;field<sizeof(good);field++) for(bit=0;bit<8;bit++) {
        c=good;((unsigned char *)&c)[field]^=(unsigned char)(1u<<bit);
        CHECK(Rx25CqV2Check(&c,good.Publish,good.Publish,good.RequestId,1,0x100000001ULL,128)!=Rx25CqV2Success);
    }
    /* Invalidation and a different generation prevent accepting the old
     * marker while a new body is assembled at the same address. */
    c=good;c.SequenceLow=2;c.Publish=0;
    CHECK(Rx25CqV2Check(&c,0,0,c.RequestId,2,0x100000002ULL,128)==Rx25CqV2Pending);
    c.Publish=good.Publish;
    CHECK(Rx25CqV2Check(&c,c.Publish,c.Publish,c.RequestId,2,0x100000002ULL,128)==Rx25CqV2Stale);
    c.Publish=0x10002;
    CHECK(Rx25CqV2Check(&c,c.Publish,c.Publish,c.RequestId,2,0x100000002ULL,128)==Rx25CqV2Success);
    if(argc==2) {
        if(fopen_s(&out,argv[1],"w") || !out) return 2;
        /* 3 command cases, each 4 u64 inputs then 8 expected u32 CQ words. */
        for(field=0;field<3;field++) {
            ULONGLONG sequence=field==2 ? 0x100000001ULL : (ULONGLONG)field+1;
            ULONG generation=field+1,length=field==1?128:16,offset=field==2?4064:field*128;
            RX25_CQ_V2 vector={0x12345678,0x10000|generation,length,(ULONG)sequence,0,
                (ULONG)(sequence>>32),RX25_CQ_V2_MAGIC,0};
            const ULONG *words=(const ULONG *)&vector;
            CHECK(Rx25CqV2Check(&vector,vector.Publish,vector.Publish,vector.RequestId,generation,sequence,length)==Rx25CqV2Success);
            fprintf(out,"%016llx %016llx %016llx %016llx",sequence,(ULONGLONG)generation,(ULONGLONG)length,(ULONGLONG)offset);
            for(bit=0;bit<8;bit++) fprintf(out," %08lx",words[bit]);
            fprintf(out,"\n");
        }
        if(fclose(out)) return 2;
    }
    printf("RX25_CQ_V2_TEST_PASS checks=%u vectors=%u\n",checks,argc==2?3:0);
    return 0;
}
