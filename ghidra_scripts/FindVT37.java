import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.address.AddressSetView;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.Instruction;
import ghidra.program.model.listing.InstructionIterator;
import ghidra.program.model.symbol.Reference;
import ghidra.program.model.symbol.ReferenceIterator;
import java.util.HashSet;
import java.util.Set;

public class FindVT37 extends GhidraScript {
    @Override
    public void run() throws Exception {
        // vt[37] is at offset +0x94 in each class's vftable.
        // Known vtable addresses:
        long[] vtables = { 0x00556594L, 0x00556b14L, 0x00556d6cL, 0x005566e4L,
                           0x005583ecL, 0x00558454L, 0x0055831cL, 0x00558384L };
        String[] names = { "TActor", "TPlayer", "TNewLiving", "TEnemy",
                           "TBullet", "TCannonBullet", "TNail", "TExplodingBullet" };
        for (int i = 0; i < vtables.length; i++) {
            Address vtable = toAddr(vtables[i]);
            Address slot = toAddr(vtables[i] + 0x94);
            try {
                long fnPtr = getInt(slot) & 0xFFFFFFFFL;
                Address fn = toAddr(fnPtr);
                Function f = getFunctionAt(fn);
                String fname = f != null ? f.getName() : "(no function)";
                println(String.format("%-20s vt[37]=+0x94 @ %s -> 0x%08x  %s",
                    names[i], slot.toString(), fnPtr, fname));
            } catch (Exception e) {
                println(String.format("%-20s vt[37] read failed: %s", names[i], e));
            }
        }
        println("\n--- Searching for call sites: 'call dword ptr [eax+0x94]' or [ecx+0x94] ---");
        // Search for the call pattern: 0xFF 0x90 0x94 0x00 0x00 0x00 (call [eax+0x94])
        // or 0xFF 0x91 0x94 0x00 0x00 0x00 (call [ecx+0x94])
        byte[][] patterns = {
            {(byte)0xFF, (byte)0x90, (byte)0x94, 0x00, 0x00, 0x00},  // call [eax+0x94]
            {(byte)0xFF, (byte)0x91, (byte)0x94, 0x00, 0x00, 0x00},  // call [ecx+0x94]
            {(byte)0xFF, (byte)0x92, (byte)0x94, 0x00, 0x00, 0x00},  // call [edx+0x94]
            {(byte)0xFF, (byte)0x93, (byte)0x94, 0x00, 0x00, 0x00},  // call [ebx+0x94]
        };
        Set<Address> found = new HashSet<>();
        for (byte[] pat : patterns) {
            Address a = currentProgram.getMinAddress();
            while (a != null) {
                a = find(a, pat);
                if (a == null) break;
                if (!found.add(a)) { a = a.add(1); continue; }
                Function f = getFunctionContaining(a);
                String fname = f != null ? f.getName() : "(no fn)";
                String entry = f != null ? f.getEntryPoint().toString() : "?";
                println(String.format("  %s  in %s @ %s", a, fname, entry));
                a = a.add(1);
            }
        }
    }
}
