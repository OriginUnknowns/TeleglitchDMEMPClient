import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.symbol.Reference;
import ghidra.program.model.symbol.ReferenceIterator;
import java.io.FileWriter;
import java.io.PrintWriter;
import java.util.HashSet;
import java.util.Set;
import java.util.LinkedList;
import java.util.Queue;

public class TraceBullet extends GhidraScript {
    PrintWriter w;
    DecompInterface decomp;

    void dumpFn(Address fa, String tag) throws Exception {
        Function f = getFunctionAt(fa);
        if (f == null) { w.println("[no fn at " + fa + "]"); return; }
        w.println("\n--- " + tag + " ---");
        w.println(String.format("FN %s @ 0x%08x   sig=%s", f.getName(), f.getEntryPoint().getOffset(), f.getSignature()));
        DecompileResults res = decomp.decompileFunction(f, 60, monitor);
        if (res.decompileCompleted() && res.getDecompiledFunction() != null) {
            w.println(res.getDecompiledFunction().getC());
        } else {
            w.println("[decomp failed: " + res.getErrorMessage() + "]");
        }
    }

    Address findStringAddr(String s) {
        // Search common string region. We have known addrs already, so allow caller to pass hex.
        return null;
    }

    @Override
    public void run() throws Exception {
        w = new PrintWriter(new FileWriter("E:\\projects\\TMEMultiplayerClient\\ghidra_trace.txt"));
        decomp = new DecompInterface();
        decomp.openProgram(currentProgram);

        // Known string addresses from prior dump
        long[] strAddrs = {
            0x0053df9cL,  // "CreateBullet"
            0x0053e3e0L,  // "_CreateWeapon"
            0x00541150L,  // "SetHealth"
            0x0053da68L,  // "shoot"
            0x005738a8L,  // TBullet TD
            0x0057332cL,  // TBulletShooter TD
            0x00573b58L,  // TRayCastBulletCallback TD
            0x0054146cL,  // "damage"
            0x00542a2cL,  // "bulletspeed"
            0x00542adcL,  // "bullettype"
        };

        for (long sa : strAddrs) {
            Address a = toAddr(sa);
            w.println("\n========== XREFS TO 0x" + Long.toHexString(sa) + " ==========");
            ReferenceIterator rit = currentProgram.getReferenceManager().getReferencesTo(a);
            Set<Address> callers = new HashSet<>();
            while (rit.hasNext()) {
                Reference r = rit.next();
                Address from = r.getFromAddress();
                Function f = getFunctionContaining(from);
                if (f != null) callers.add(f.getEntryPoint());
                w.println(String.format("  from 0x%08x in %s", from.getOffset(),
                    f != null ? f.getName() : "<no fn>"));
            }
            // Decompile each unique caller
            int n = 0;
            for (Address ca : callers) {
                if (++n > 4) { w.println("  (skipping more callers)"); break; }
                dumpFn(ca, String.format("CALLER OF 0x%x", sa));
            }
        }

        w.close();
        println("WROTE: E:\\projects\\TMEMultiplayerClient\\ghidra_trace.txt");
    }
}
