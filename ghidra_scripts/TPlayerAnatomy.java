import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.symbol.Reference;
import java.io.FileWriter;
import java.io.PrintWriter;
import java.util.HashSet;
import java.util.Set;

public class TPlayerAnatomy extends GhidraScript {
    PrintWriter w; DecompInterface decomp;
    long rd(long a) throws Exception { return currentProgram.getMemory().getInt(toAddr(a)) & 0xffffffffL; }
    void d(long a, String tag) throws Exception {
        Function f=getFunctionAt(toAddr(a)); if(f==null)f=createFunction(toAddr(a),null);
        if(f==null){w.println("[no fn @0x"+Long.toHexString(a)+"]");return;}
        w.println("\n===== "+tag+" "+f.getName()+" @ 0x"+Long.toHexString(a)+" =====");
        DecompileResults r=decomp.decompileFunction(f,90,monitor);
        if(r.decompileCompleted()&&r.getDecompiledFunction()!=null)w.println(r.getDecompiledFunction().getC());
        else w.println("[fail]");
    }
    @Override public void run() throws Exception {
        w=new PrintWriter(new FileWriter("E:\\projects\\TMEMultiplayerClient\\ghidra_tplayer_anatomy.txt"));
        decomp=new DecompInterface(); decomp.openProgram(currentProgram);

        // --- Who reads the main-player global DAT_005747a4? (camera/HUD/input) ---
        w.println("=== XREFS to player global DAT_005747a4 (0x5747a4) ===");
        Set<Long> readers = new HashSet<>();
        for (Reference r : currentProgram.getReferenceManager().getReferencesTo(toAddr(0x5747a4L))) {
            Function f = getFunctionContaining(r.getFromAddress());
            String rt = r.getReferenceType().toString();
            w.println(String.format("  0x%08x [%s] in %s", r.getFromAddress().getOffset(), rt,
                f != null ? f.getName() : "<none>"));
            if (f != null) readers.add(f.getEntryPoint().getOffset());
        }
        w.println("unique funcs touching player global: " + readers.size());

        // --- TPlayer vtable override methods (the 0x45xxxx ones) to categorize ---
        // [9]=0x45ef70 [10]=0x45cbc0(think) [11]=0x45bff0 [14]=0x45c220
        // [21]=0x45ebd0 [24]=0x45e900 [31]=0x460b00 [0]=0x45b980(dtor)
        d(0x45c220L, "vtable[14] +0x38");
        d(0x45ebd0L, "vtable[21] +0x54");
        d(0x45e900L, "vtable[24] +0x60");
        d(0x460b00L, "vtable[31] +0x7c");
        d(0x45ef70L, "vtable[9] +0x24 (registers lua methods)");
        w.close();
        println("WROTE: E:\\projects\\TMEMultiplayerClient\\ghidra_tplayer_anatomy.txt");
    }
}
