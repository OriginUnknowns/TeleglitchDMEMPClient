import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.listing.Function;
import java.io.FileWriter;
import java.io.PrintWriter;

public class DecompCamInput extends GhidraScript {
    PrintWriter w; DecompInterface decomp;
    void d(long a, String tag) throws Exception {
        Function f=getFunctionAt(toAddr(a)); if(f==null)f=createFunction(toAddr(a),null);
        if(f==null){w.println("[no fn @0x"+Long.toHexString(a)+"]");return;}
        w.println("\n===== "+tag+" "+f.getName()+" @ 0x"+Long.toHexString(a)+" =====");
        DecompileResults r=decomp.decompileFunction(f,120,monitor);
        if(r.decompileCompleted()&&r.getDecompiledFunction()!=null)w.println(r.getDecompiledFunction().getC());
        else w.println("[fail]");
    }
    @Override public void run() throws Exception {
        w=new PrintWriter(new FileWriter("E:\\projects\\TMEMultiplayerClient\\ghidra_caminput.txt"));
        decomp=new DecompInterface(); decomp.openProgram(currentProgram);
        d(0x4cc8e0L, "FUN_004cc8e0 (reads player global 3x - view/camera?)");
        d(0x485510L, "FUN_00485510 (reads player global)");
        d(0x4542f0L, "FUN_004542f0 (alive-think: input/camera/move)");
        w.close();
        println("WROTE: E:\\projects\\TMEMultiplayerClient\\ghidra_caminput.txt");
    }
}
