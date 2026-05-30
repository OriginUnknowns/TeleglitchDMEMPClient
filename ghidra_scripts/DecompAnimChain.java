import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.listing.Function;
import java.io.FileWriter;
import java.io.PrintWriter;

public class DecompAnimChain extends GhidraScript {
    PrintWriter w; DecompInterface decomp;
    void d(long a, String tag) throws Exception {
        Function f = getFunctionContaining(toAddr(a));
        if (f==null) f=getFunctionAt(toAddr(a));
        if (f==null){w.println("\n[no fn @0x"+Long.toHexString(a)+"]");return;}
        w.println("\n===== "+tag+" -> "+f.getName()+" @ 0x"+Long.toHexString(f.getEntryPoint().getOffset())
            +" (addr 0x"+Long.toHexString(a)+") =====");
        DecompileResults r=decomp.decompileFunction(f,60,monitor);
        if(r.decompileCompleted()&&r.getDecompiledFunction()!=null)w.println(r.getDecompiledFunction().getC());
        else w.println("[fail]");
    }
    @Override public void run() throws Exception {
        w=new PrintWriter(new FileWriter("E:\\projects\\TMEMultiplayerClient\\ghidra_animchain.txt"));
        decomp=new DecompInterface(); decomp.openProgram(currentProgram);
        d(0x45f6baL, "F3-CRASH (mov eax,[edx+0x1c])");
        d(0x466b01L, "F2-caller");
        d(0x46465eL, "render FUN_00464040 caller-site");
        w.close();
        println("WROTE: E:\\projects\\TMEMultiplayerClient\\ghidra_animchain.txt");
    }
}
