import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.listing.Function;
import ghidra.program.model.symbol.Reference;
import java.io.FileWriter;
import java.io.PrintWriter;

public class DecompPlayerWriter extends GhidraScript {
    PrintWriter w; DecompInterface decomp;
    void d(long a, String tag) throws Exception {
        Function f=getFunctionAt(toAddr(a)); if(f==null)f=createFunction(toAddr(a),null);
        if(f==null){w.println("[no fn @0x"+Long.toHexString(a)+"]");return;}
        w.println("\n===== "+tag+" "+f.getName()+" @ 0x"+Long.toHexString(a)+" =====");
        DecompileResults r=decomp.decompileFunction(f,90,monitor);
        if(r.decompileCompleted()&&r.getDecompiledFunction()!=null)w.println(r.getDecompiledFunction().getC());
        else w.println("[fail]");
    }
    @Override public void run() throws Exception {
        w=new PrintWriter(new FileWriter("E:\\projects\\TMEMultiplayerClient\\ghidra_playerwriter.txt"));
        decomp=new DecompInterface(); decomp.openProgram(currentProgram);
        d(0x417460L, "FUN_00417460 (2nd writer of player global)");
        // who calls FUN_00417460? (per-frame? on event?)
        w.println("\n=== callers of FUN_00417460 ===");
        for (Reference r : currentProgram.getReferenceManager().getReferencesTo(toAddr(0x417460L))) {
            Function f=getFunctionContaining(r.getFromAddress());
            w.println(String.format("  from 0x%08x in %s", r.getFromAddress().getOffset(), f!=null?f.getName():"<none>"));
        }
        w.close();
        println("WROTE: E:\\projects\\TMEMultiplayerClient\\ghidra_playerwriter.txt");
    }
}
