import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import java.io.FileWriter;
import java.io.PrintWriter;

public class DecompMore extends GhidraScript {
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
        w = new PrintWriter(new FileWriter("E:\\projects\\TMEMultiplayerClient\\ghidra_damage_path.txt"));
        decomp = new DecompInterface();
        decomp.openProgram(currentProgram);

        // TPlayer ctor
        d(0x0045b410L, "TPlayer ctor");
        // TPlayer OnHitByBullet (vtable[19])
        d(0x0044f210L, "TPlayer::OnHitByBullet (vftable[19])");
        // TZombieMover OnHitByBullet (vtable[19])
        d(0x00468ec0L, "TZombieMover::OnHitByBullet (vftable[19])");
        // TZombieSpawner OnHitByBullet (vtable[19])
        d(0x00494990L, "TZombieSpawner::OnHitByBullet (vftable[19])");
        // Also the bullet's own vtable[20] for the mob (FUN_00496920 done, but let's get FUN_00497740 = TCannonBullet variant)
        d(0x00497740L, "TCannonBullet::vftable[20]");
        // ApplyDamage candidates - try to find "TakeDamage" or "ApplyDamage" -- look for FUN that calls SetHealth
        // FUN_00498ad0's "type == 2" path also calls bullet->vtable[+0x50] = TBullet::FUN_00496920 (already have)
        // Decompile FUN_004959b0 (TBullet vtable[0]) — fully
        // (already in bullet_methods)

        w.close();
        println("WROTE: E:\\projects\\TMEMultiplayerClient\\ghidra_damage_path.txt");
    }
}
