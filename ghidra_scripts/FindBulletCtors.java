import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.address.AddressIterator;
import ghidra.program.model.address.AddressSetView;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.Instruction;
import ghidra.program.model.mem.Memory;
import ghidra.program.model.scalar.Scalar;
import java.io.FileWriter;
import java.io.PrintWriter;
import java.util.LinkedHashMap;
import java.util.Map;

// Find every function that writes one of the bullet-subclass vtable
// addresses into [this]/[ecx]/[reg]. That's the ctor prologue pattern
// in MSVC: `mov dword ptr [this], <vtable_addr>`. Emits a table of
// {vtable_name -> ctor_addr(s)} which is what we need to hook each
// subclass's construction.
public class FindBulletCtors extends GhidraScript {
    @Override
    public void run() throws Exception {
        PrintWriter w = new PrintWriter(new FileWriter("E:\\projects\\TMEMultiplayerClient\\ghidra_bullet_ctors.txt"));
        Map<Long, String> vtables = new LinkedHashMap<>();
        vtables.put(0x005583ecL, "TBullet");
        vtables.put(0x00558454L, "TCannonBullet");
        vtables.put(0x00558384L, "TExplodingBullet");
        vtables.put(0x0055831cL, "TNail");
        vtables.put(0x005584bcL, "TLaser");
        vtables.put(0x005585acL, "TRailgunRay");
        vtables.put(0x005586c4L, "TRocket");
        vtables.put(0x00558604L, "TBlueRocket");

        Memory mem = currentProgram.getMemory();
        for (Map.Entry<Long, String> e : vtables.entrySet()) {
            long vt = e.getKey();
            String name = e.getValue();
            w.println("=== " + name + " vftable @ 0x" + Long.toHexString(vt) + " ===");
            // Walk instructions; find MOV imm32 writes of vt.
            AddressIterator it = mem.getAllInitializedAddressSet().getAddresses(true);
            int hits = 0;
            while (it.hasNext() && hits < 32) {
                Address a = it.next();
                Instruction insn = getInstructionAt(a);
                if (insn == null) continue;
                String mnem = insn.getMnemonicString();
                if (!mnem.equals("MOV")) continue;
                if (insn.getNumOperands() < 2) continue;
                // Operand 1 (src) must be a scalar matching vt.
                Object[] ops = insn.getOpObjects(1);
                boolean match = false;
                for (Object o : ops) {
                    if (o instanceof Scalar) {
                        long v = ((Scalar) o).getUnsignedValue();
                        if (v == vt) { match = true; break; }
                    }
                }
                if (!match) continue;
                Function f = getFunctionContaining(a);
                String fname = (f != null) ? f.getName() + "@0x" + Long.toHexString(f.getEntryPoint().getOffset()) : "<no-fn>";
                w.println(String.format("  insn 0x%08x  %s  (%s)", a.getOffset(), insn.toString(), fname));
                hits++;
            }
            if (hits == 0) w.println("  (no MOV imm32 references found)");
            w.println();
        }
        w.close();
        println("WROTE: E:\\projects\\TMEMultiplayerClient\\ghidra_bullet_ctors.txt");
    }
}
