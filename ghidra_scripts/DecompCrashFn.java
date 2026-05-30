import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.listing.Function;
import java.io.FileWriter;
import java.io.PrintWriter;

public class DecompCrashFn extends GhidraScript {
    PrintWriter w; DecompInterface decomp;
    void d(long a, String tag) throws Exception {
        Function f = getFunctionContaining(toAddr(a));
        if (f==null) f=getFunctionAt(toAddr(a));
        if (f==null){w.println("[no fn @0x"+Long.toHexString(a)+"]");return;}
        w.println("\n===== "+tag+" "+f.getName()+" @ 0x"+Long.toHexString(f.getEntryPoint().getOffset())
            +" (crash ret 0x"+Long.toHexString(a)+") =====");
        DecompileResults r=decomp.decompileFunction(f,60,monitor);
        if(r.decompileCompleted()&&r.getDecompiledFunction()!=null)w.println(r.getDecompiledFunction().getC());
        else w.println("[fail]");
    }
    @Override public void run() throws Exception {
        w=new PrintWriter(new FileWriter("E:\\projects\\TMEMultiplayerClient\\ghidra_crashfn.txt"));
        decomp=new DecompInterface(); decomp.openProgram(currentProgram);
        d(0x46466eL, "crash-fn");          // reads [eax+0x70]
        d(0x400000L+0x17899L, "caller1");  // Debug_miks+0x17899
        w.close();
        println("WROTE: E:\\projects\\TMEMultiplayerClient\\ghidra_crashfn.txt");
    }
}
