// dp_dump.cpp — print the full H matrix (ksw-faithful unbanded local DP) for a
// single hardcoded extension, to compare against an RTL cell dump.
#include <cstdio>
#include <vector>
#include <cstring>
int main() {
    // case [19]: qlen=6 tlen=7 h0=143 o_del=6 e_del=1 o_ins=6 e_ins=1
    int qlen=6, tlen=7, h0=143, o_del=6,e_del=1,o_ins=6,e_ins=1;
    int q[]={1,3,3,2,3,0};
    int t[]={3,3,3,2,3,0,0};
    // score matrix a=1,b=4,ambig=-1
    auto sc=[&](int qq,int tt){ if(qq>4||tt>4)return -1; if(qq==4||tt==4)return -1; return qq==tt?1:-4; };
    int oe_del=o_del+e_del, oe_ins=o_ins+e_ins;
    std::vector<int> H(qlen+1), E(qlen+1);
    H[0]=h0; E[0]=0;
    if(qlen>0){H[1]=h0-oe_ins; if(H[1]<0)H[1]=0; E[1]=0;}
    for(int j=2;j<=qlen;++j){H[j]=H[j-1]-e_ins; if(H[j]<0)H[j]=0; E[j]=0;}
    printf("init eh: "); for(int j=0;j<qlen;++j) printf("%d ",H[j]); printf("\n");
    int gmax=h0,gi=-1,gj=-1,gscore=-1,gtle=-1;
    for(int i=0;i<tlen;++i){
        int f=0,h1,mm=0,mj=-1;
        h1=h0-(o_del+e_del*(i+1)); if(h1<0)h1=0;
        printf("row %d (t=%d): ",i,t[i]);
        for(int j=0;j<qlen;++j){
            int M=H[j],e=E[j];
            H[j]=h1;
            M=M?M+sc(q[j],t[i]):0;
            int h=M>e?M:e; h=h>f?h:f;
            h1=h;
            printf("%d ",h);
            mj=mm>h?mj:j; mm=mm>h?mm:h;
            int tt=M-oe_del; tt=tt>0?tt:0; e-=e_del; e=e>tt?e:tt; E[j]=e;
            tt=M-oe_ins; tt=tt>0?tt:0; f-=e_ins; f=f>tt?f:tt;
        }
        H[qlen]=h1; E[qlen]=0;
        printf(" | last(H[%d,%d])=%d rowmax=%d@j%d\n",i,qlen-1,h1,mm,mj);
        if(h1>gscore){gscore=h1;gtle=i+1;}
        if(mm>gmax){gmax=mm;gi=i;gj=mj;}
    }
    printf("RESULT score=%d qle=%d tle=%d gscore=%d gtle=%d\n",gmax,gj+1,gi+1,gscore,gtle);
    return 0;
}
