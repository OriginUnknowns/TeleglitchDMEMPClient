import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Instruction;
import ghidra.program.model.scalar.Scalar;
import ghidra.program.model.symbol.Reference;
import ghidra.program.model.symbol.ReferenceIterator;
import ghidra.program.model.symbol.ReferenceManager;
import java.io.FileWriter;
import java.io.PrintWriter;
import java.util.LinkedHashMap;
import java.util.Map;

// For each subclass ctor, find every call site and walk BACKWARDS up to
// ~30 instructions looking for `PUSH imm` (operator_new(size)) — that
// arg is the object size we need to allocate in our own native binding.
public class FindCtorAllocSizes extends GhidraScript {
    @Override
    public void run() throws Exception {
        PrintWriter w = new PrintWriter(new FileWriter("E:\\projects\\TMEMultiplayerClient\\ghidra_ctor_alloc_sizes.txt"));
        Map<Long, String> ctors = new LinkedHashMap<>();
        ctors.put(0x00497040L, "TBullet");
        ctors.put(0x00497660L, "TCannonBullet");
        ctors.put(0x00497140L, "TExplodingBullet");
        ctors.put(0x00497200L, "TNail");
        ctors.put(0x00497cd0L, "TLaser");
        ctors.put(0x00499d70L, "TRailgunRay");
        ctors.put(0x0049a5c0L, "TRocket");
        ctors.put(0x0049aa10L, "TBlueRocket");

        ReferenceManager rm = currentProgram.getReferenceManager();
        for (Map.Entry<Long, String> e : ctors.entrySet()) {
            Address ctorAddr = toAddr(e.getKey());
            w.println("== " + e.getValue() + " ctor @ 0x" + Long.toHexString(e.getKey()));
            ReferenceIterator refs = rm.getReferencesTo(ctorAddr);
            int siteN = 0;
            while (refs.hasNext()) {
                Reference r = refs.next();
                Address callSite = r.getFromAddress();
                Instruction ci = getInstructionAt(callSite);
                if (ci == null || !ci.getMnemonicString().startsWith("CALL")) continue;
                siteN++;
                w.println("  call site #" + siteN + " @ 0x" + Long.toHexString(callSite.getOffset()));
                // Walk backward.
                Instruction prev = ci.getPrevious();
                int backCount = 0;
                long latestPushImm = -1;
                Address latestPushAddr = null;
                while (prev != null && backCount < 50) {
                    String mn = prev.getMnemonicString();
                    if (mn.equals("PUSH") && prev.getNumOperands() >= 1) {
                        Object[] ops = prev.getOpObjects(0);
                        for (Object o : ops) {
                            if (o instanceof Scalar) {
                                long v = ((Scalar) o).getUnsignedValue();
                                // Plausible sizes for these objects fit in
                                // a byte. Anything > 0x200 is almost
                                // certainly an address, not a size.
                                if (v > 0 && v < 0x200) {
                                    latestPushImm = v;
                                    latestPushAddr = prev.getAddress();
                                }
                            }
                        }
                    }
                    if (latestPushImm > 0) break;  // first push backward is the size arg
                    prev = prev.getPrevious();
                    backCount++;
                }
                if (latestPushImm > 0) {
                    w.println("    nearest PUSH imm: 0x" + Long.toHexString(latestPushImm) +
                              " @ 0x" + Long.toHexString(latestPushAddr.getOffset()));
                } else {
                    w.println("    no PUSH imm found within 50 prior instructions");
                }
                if (siteN >= 6) break;
            }
            w.println();
        }
        w.close();
        println("WROTE: E:\\projects\\TMEMultiplayerClient\\ghidra_ctor_alloc_sizes.txt");
    }
}
