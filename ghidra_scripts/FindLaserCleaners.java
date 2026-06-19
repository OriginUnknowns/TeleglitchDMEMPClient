import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.address.Address;
import ghidra.program.model.address.AddressIterator;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.Instruction;
import ghidra.program.model.mem.Memory;
import ghidra.program.model.scalar.Scalar;
import java.io.FileWriter;
import java.io.PrintWriter;
import java.util.LinkedHashSet;
import java.util.Set;

// Find every function that references TLaser::vftable (0x5584bc) — the
// candidates for "laser-aware code paths" that might handle cleanup,
// render, or maintain a separate laser-list independent of vt[22].
public class FindLaserCleaners extends GhidraScript {
    @Override
    public void run() throws Exception {
        PrintWriter w = new PrintWriter(new FileWriter("E:\\projects\\TMEMultiplayerClient\\ghidra_laser_cleaners.txt"));
        Memory mem = currentProgram.getMemory();
        long TLASER_VTABLE = 0x005584bcL;
        Set<String> seen = new LinkedHashSet<>();
        AddressIterator it = mem.getAllInitializedAddressSet().getAddresses(true);
        while (it.hasNext()) {
            Address a = it.next();
            Instruction ins = getInstructionAt(a);
            if (ins == null) continue;
            for (int oi = 0; oi < ins.getNumOperands(); oi++) {
                Object[] ops = ins.getOpObjects(oi);
                for (Object o : ops) {
                    long v = -1;
                    if (o instanceof Scalar) v = ((Scalar) o).getUnsignedValue();
                    else if (o instanceof Address) v = ((Address) o).getOffset();
                    if (v == TLASER_VTABLE) {
                        Function f = getFunctionContaining(a);
                        String key = f != null
                            ? f.getName() + "@0x" + Long.toHexString(f.getEntryPoint().getOffset())
                            : "<no-fn>";
                        if (!seen.add(key)) break;
                        w.println(String.format("  ref at 0x%08x  %s  (%s)",
                            a.getOffset(), ins.toString(), key));
                        if (f != null && seen.size() <= 8) {
                            DecompInterface decomp = new DecompInterface();
                            decomp.openProgram(currentProgram);
                            DecompileResults dr = decomp.decompileFunction(f, 60, monitor);
                            if (dr != null && dr.getDecompiledFunction() != null) {
                                w.println(dr.getDecompiledFunction().getC());
                            }
                            w.println("\n----\n");
                        }
                    }
                }
            }
            if (seen.size() >= 20) break;
        }
        w.close();
        println("WROTE: E:\\projects\\TMEMultiplayerClient\\ghidra_laser_cleaners.txt");
    }
}
