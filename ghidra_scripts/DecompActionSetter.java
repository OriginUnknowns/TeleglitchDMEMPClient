import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.listing.Function;
import java.io.FileWriter;
import java.io.PrintWriter;

public class DecompActionSetter extends GhidraScript {
    PrintWriter w; DecompInterface decomp;
    void d(long a, String tag) throws Exception {
        Function f=getFunctionAt(toAddr(a)); if(f==null)f=createFunction(toAddr(a),null);
        if(f==null){w.println("[no fn @0x"+Long.toHexString(a)+"]");return;}
        w.println("\n===== "+tag+" "+f.getName()+" @ 0x"+Long.toHexString(a)+" =====");
        DecompileResults r=decomp.decompileFunction(f,60,monitor);
        if(r.decompileCompleted()&&r.getDecompiledFunction()!=null)w.println(r.getDecompiledFunction().getC());
        else w.println("[fail]");
    }
    @Override public void run() throws Exception {
        w=new PrintWriter(new FileWriter("E:\\projects\\TMEMultiplayerClient\\ghidra_actionsetter.txt"));
        decomp=new DecompInterface(); decomp.openProgram(currentProgram);
        d(0x44ddc0L, "TActor::vtable+0x50 SetAction(action)");
        // FUN_004667a0 is used by FUN_0045f170 to check the active action; it
        // likely reads the action-id field — reveals the read offset too.
        d(0x4667a0L, "FUN_004667a0 (action check)");
        w.close();
        println("WROTE: E:\\projects\\TMEMultiplayerClient\\ghidra_actionsetter.txt");
    }
}
