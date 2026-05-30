import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.listing.Function;
import java.io.FileWriter;
import java.io.PrintWriter;

public class DecompPlayerUpdate extends GhidraScript {
    PrintWriter w; DecompInterface decomp;
    void d(long a, String tag) throws Exception {
        Function f=getFunctionAt(toAddr(a)); if(f==null)f=createFunction(toAddr(a),null);
        if(f==null){w.println("[no fn @0x"+Long.toHexString(a)+"]");return;}
        w.println("\n===== "+tag+" "+f.getName()+" @ 0x"+Long.toHexString(a)+" =====");
        DecompileResults r=decomp.decompileFunction(f,90,monitor);
        if(r.decompileCompleted()&&r.getDecompiledFunction()!=null)w.println(r.getDecompiledFunction().getC());
        else w.println("[fail]");
    }
    long rd(long a) throws Exception { return currentProgram.getMemory().getInt(toAddr(a)) & 0xffffffffL; }
    @Override public void run() throws Exception {
        w=new PrintWriter(new FileWriter("E:\\projects\\TMEMultiplayerClient\\ghidra_playerupdate.txt"));
        decomp=new DecompInterface(); decomp.openProgram(currentProgram);
        // TPlayer::vftable @ 0x556b14 — dump slots so we can ID Update/Think.
        long vt=0x556b14L;
        w.println("=== TPlayer vtable slots ===");
        for(int i=0;i<32;i++){ long fa=rd(vt+i*4); if(fa<0x400000||fa>0x600000)break;
            w.println(String.format("  [%2d] (+0x%02x) 0x%08x", i, i*4, fa)); }
        // Decompile the likely think/update slots (TPlayer-specific overrides):
        // [9]=0x45ef70 [10]=0x45cbc0 [11]=0x45bff0 [14]=0x45c220 [21]=0x45ebd0 [24]=0x45e900 [31]=0x460b00
        d(0x45cbc0L, "vtable[10] +0x28");
        d(0x45bff0L, "vtable[11] +0x2c");
        d(0x45c220L, "vtable[14] +0x38");
        w.close();
        println("WROTE: E:\\projects\\TMEMultiplayerClient\\ghidra_playerupdate.txt");
    }
}
