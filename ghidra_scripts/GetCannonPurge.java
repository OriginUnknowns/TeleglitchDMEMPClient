import ghidra.app.script.GhidraScript;
import ghidra.program.model.listing.Instruction;
import ghidra.program.model.listing.InstructionIterator;
import ghidra.program.model.address.Address;
import ghidra.program.model.address.AddressSet;
import ghidra.program.model.listing.Function;

public class GetCannonPurge extends GhidraScript {
    @Override
    public void run() throws Exception {
        long[] addrs = { 0x00497660L, 0x00497140L, 0x00497200L, 0x004958b0L };
        String[] names = { "Cannon", "Explode", "Nail", "Adhgrenade" };
        for (int i = 0; i < addrs.length; i++) {
            Address a = toAddr(addrs[i]);
            Function f = getFunctionContaining(a);
            if (f == null) { println(names[i] + ": NO function at " + a); continue; }
            AddressSet body = new AddressSet(f.getBody());
            InstructionIterator it = currentProgram.getListing().getInstructions(body, true);
            String last = null;
            while (it.hasNext()) {
                Instruction ins = it.next();
                String mnem = ins.getMnemonicString();
                if (mnem.equalsIgnoreCase("RET") || mnem.equalsIgnoreCase("RETN")) {
                    last = ins.toString();
                    // keep iterating; last RET wins
                }
            }
            println(names[i] + " (" + f.getName() + ") last RET: " + last);
        }
    }
}
