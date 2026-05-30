import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.listing.Function;
import java.io.FileWriter;
import java.io.PrintWriter;

public class DecompSetAction extends GhidraScript {
    PrintWriter w; DecompInterface decomp;
    void d(long a, String tag) throws Exception {
        Function f=getFunctionAt(toAddr(a)); if(f==null)f=createFunction(toAddr(a),null);
        if(f==null){w.println("[no fn]");return;}
        w.println("\n===== "+tag+" "+f.getName()+" @ 0x"+Long.toHexString(a)+" =====");
        DecompileResults r=decomp.decompileFunction(f,60,monitor);
        if(r.decompileCompleted()&&r.getDecompiledFunction()!=null)w.println(r.getDecompiledFunction().getC());
        else w.println("[fail]");
    }
    @Override public void run() throws Exception {
        w=new PrintWriter(new FileWriter("E:\\projects\\TMEMultiplayerClient\\ghidra_setaction2.txt"));
        decomp=new DecompInterface(); decomp.openProgram(currentProgram);
        d(0x44ea00L, "SetAction-cfunc");
        d(0x44eb00L, "GetAction-cfunc");
        w.close();
        println("WROTE: E:\\projects\\TMEMultiplayerClient\\ghidra_setaction2.txt");
    }
}
