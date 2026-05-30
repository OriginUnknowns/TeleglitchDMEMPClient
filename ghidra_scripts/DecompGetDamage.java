import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import java.io.FileWriter;
import java.io.PrintWriter;

public class DecompGetDamage extends GhidraScript {
    PrintWriter w;
    DecompInterface decomp;

    void d(long a, String tag) throws Exception {
        Function f = getFunctionAt(toAddr(a));
        if (f == null) f = createFunction(toAddr(a), null);
        if (f == null) { w.println("[no fn at 0x" + Long.toHexString(a) + "]"); return; }
        w.println("\n========== " + tag + " " + f.getName() + " @ 0x" + Long.toHexString(a) + " ==========");
        DecompileResults res = decomp.decompileFunction(f, 60, monitor);
        if (res.decompileCompleted() && res.getDecompiledFunction() != null) {
            w.println(res.getDecompiledFunction().getC());
        } else {
            w.println("[decomp failed]");
        }
    }

    @Override
    public void run() throws Exception {
        w = new PrintWriter(new FileWriter("E:\\projects\\TMEMultiplayerClient\\ghidra_getdamage.txt"));
        decomp = new DecompInterface();
        decomp.openProgram(currentProgram);

        // TBullet::vftable[23] @ +0x5c -- candidate GetDamage
        d(0x00496900L, "TBullet::GetDamage? (vftable[23])");
        // TCannonBullet's variant
        d(0x00495830L, "TCannonBullet::GetDamage? (vftable[23])");

        // helpers called from FUN_0044ee80
        d(0x0044dd70L, "TActor helper (FUN_0044dd70)");

        // TActor::vftable[24] (+0x60) TakeDamage
        d(0x0044e3e0L, "TActor::TakeDamage (vftable[24] +0x60)");

        // TBullet::vftable[22] = FUN_00498f50 -- another candidate
        d(0x00498f50L, "TBullet::vftable[22]");

        w.close();
        println("WROTE: E:\\projects\\TMEMultiplayerClient\\ghidra_getdamage.txt");
    }
}
