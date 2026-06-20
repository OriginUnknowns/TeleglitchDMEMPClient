import ghidra.app.script.GhidraScript;
import ghidra.program.model.listing.Instruction;
import ghidra.program.model.listing.InstructionIterator;
import ghidra.program.model.address.Address;
import ghidra.program.model.address.AddressSet;
import ghidra.program.model.listing.Function;

public class GetVtPurge extends GhidraScript {
    @Override
    public void run() throws Exception {
        long[] addrs = { 0x00498ad0L, 0x0044f210L, 0x00497770L, 0x00436aa0L, 0x0049ee40L };
        String[] names = { "vt11_shared", "actor_vt19", "cannon_boom", "post_ctor_stats", "steam_stats" };
        for (int i = 0; i < addrs.length; i++) {
            Address a = toAddr(addrs[i]);
            Function f = getFunctionContaining(a);
            if (f == null) { println(names[i] + ": NO function"); continue; }
            AddressSet body = new AddressSet(f.getBody());
            InstructionIterator it = currentProgram.getListing().getInstructions(body, true);
            String last = null;
            while (it.hasNext()) {
                Instruction ins = it.next();
                String mnem = ins.getMnemonicString();
                if (mnem.equalsIgnoreCase("RET") || mnem.equalsIgnoreCase("RETN")) last = ins.toString();
            }
            println(names[i] + " (" + f.getName() + ") last RET: " + last);
        }
    }
}
