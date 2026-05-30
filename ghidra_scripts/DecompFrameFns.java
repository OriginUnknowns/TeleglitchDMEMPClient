import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.listing.Function;
import java.io.FileWriter;
import java.io.PrintWriter;

public class DecompFrameFns extends GhidraScript {
    PrintWriter w; DecompInterface decomp;
    void d(long a, String tag) throws Exception {
        Function f = getFunctionAt(toAddr(a));
        if (f==null) f=createFunction(toAddr(a),null);
        if (f==null){w.println("[no fn]");return;}
        w.println("\n===== "+tag+" "+f.getName()+" @ 0x"+Long.toHexString(a)+" =====");
        DecompileResults r=decomp.decompileFunction(f,60,monitor);
        if(r.decompileCompleted()&&r.getDecompiledFunction()!=null)w.println(r.getDecompiledFunction().getC());
        else w.println("[fail]");
    }
    @Override public void run() throws Exception {
        w=new PrintWriter(new FileWriter("E:\\projects\\TMEMultiplayerClient\\ghidra_framefns.txt"));
        decomp=new DecompInterface(); decomp.openProgram(currentProgram);
        d(0x4bd4c0L, "SetFrame-cfunc");
        d(0x4bd600L, "GetFrame-cfunc");
        w.close();
        println("WROTE: E:\\projects\\TMEMultiplayerClient\\ghidra_framefns.txt");
    }
}
