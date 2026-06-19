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

// Find every MOV-imm32 write where the destination is DAT_00573e00 / e04
// (the laser ctor's mystery globals — both 0 at static, must be populated
// at runtime). The writer function is where the muzzle/aim direction
// values get cached; we need to mimic that on the receiver side OR find
// a different code path to spawn a TLaser without depending on them.
public class FindDatWriters extends GhidraScript {
    @Override
    public void run() throws Exception {
        PrintWriter w = new PrintWriter(new FileWriter("E:\\projects\\TMEMultiplayerClient\\ghidra_dat_573e_writers.txt"));
        long[] targets = { 0x00573e00L, 0x00573e04L };
        Memory mem = currentProgram.getMemory();
        for (long t : targets) {
            w.println("\n=== Writers of 0x" + Long.toHexString(t) + " ===");
            AddressIterator it = mem.getAllInitializedAddressSet().getAddresses(true);
            int hits = 0;
            while (it.hasNext() && hits < 60) {
                Address a = it.next();
                Instruction ins = getInstructionAt(a);
                if (ins == null) continue;
                String mn = ins.getMnemonicString();
                if (!mn.startsWith("MOV") && !mn.startsWith("MOVSS") && !mn.startsWith("MOVQ")) continue;
                // Look for memory ref to target address.
                if (ins.getNumOperands() < 2) continue;
                boolean targetDest = false;
                Object[] ops = ins.getOpObjects(0);
                for (Object o : ops) {
                    if (o instanceof Scalar) {
                        long v = ((Scalar) o).getUnsignedValue();
                        if (v == t) { targetDest = true; break; }
                    }
                    if (o instanceof Address) {
                        long v = ((Address) o).getOffset();
                        if (v == t) { targetDest = true; break; }
                    }
                }
                if (!targetDest) continue;
                Function f = getFunctionContaining(a);
                String fname = (f != null) ? f.getName() + "@0x" + Long.toHexString(f.getEntryPoint().getOffset()) : "<no-fn>";
                w.println(String.format("  0x%08x  %s  (%s)", a.getOffset(), ins.toString(), fname));
                hits++;
            }
        }
        w.close();
        println("WROTE: E:\\projects\\TMEMultiplayerClient\\ghidra_dat_573e_writers.txt");
    }
}
