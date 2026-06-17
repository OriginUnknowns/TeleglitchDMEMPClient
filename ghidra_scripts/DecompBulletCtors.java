import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import java.io.FileWriter;
import java.io.PrintWriter;

public class DecompBulletCtors extends GhidraScript {
    @Override
    public void run() throws Exception {
        PrintWriter w = new PrintWriter(new FileWriter("E:\\projects\\TMEMultiplayerClient\\ghidra_bullet_ctors_decomp.txt"));
        DecompInterface decomp = new DecompInterface();
        decomp.openProgram(currentProgram);
        long[] ctors = { 0x00497040L, 0x00497660L, 0x00497140L, 0x00497200L,
                         0x00497cd0L, 0x00499d70L, 0x0049a5c0L, 0x0049aa10L };
        String[] names = { "TBullet", "TCannonBullet", "TExplodingBullet", "TNail",
                           "TLaser", "TRailgunRay", "TRocket", "TBlueRocket" };
        for (int i = 0; i < ctors.length; i++) {
            Address a = toAddr(ctors[i]);
            Function f = getFunctionAt(a);
            if (f == null) f = createFunction(a, names[i] + "_ctor");
            w.println("=== " + names[i] + " ctor @ 0x" + Long.toHexString(ctors[i]) + " ===");
            DecompileResults dr = decomp.decompileFunction(f, 60, monitor);
            if (dr != null && dr.getDecompiledFunction() != null) {
                w.println(dr.getDecompiledFunction().getC());
            } else {
                w.println("(decomp failed)");
            }
            w.println();
        }
        // Also: the Lua binding FUN_00425ca0 (CreateBullet)
        Address bind = toAddr(0x00425ca0L);
        Function bf = getFunctionAt(bind);
        if (bf == null) bf = createFunction(bind, "CreateBullet_binding");
        w.println("=== CreateBullet Lua binding @ 0x425ca0 ===");
        DecompileResults dr = decomp.decompileFunction(bf, 60, monitor);
        if (dr != null && dr.getDecompiledFunction() != null) {
            w.println(dr.getDecompiledFunction().getC());
        } else {
            w.println("(decomp failed)");
        }
        w.close();
        println("WROTE: E:\\projects\\TMEMultiplayerClient\\ghidra_bullet_ctors_decomp.txt");
    }
}
