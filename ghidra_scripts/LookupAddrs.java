import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;

public class LookupAddrs extends GhidraScript {
    @Override
    public void run() throws Exception {
        long[] addrs = { 0x0050d0eeL, 0x0079da40L, 0x004028f4L, 0x0041975cL };
        for (long a : addrs) {
            Address addr = toAddr(a);
            Function f = getFunctionContaining(addr);
            if (f != null) {
                println(String.format("0x%08x -> %s @ 0x%s  (offset +0x%x)",
                    a, f.getName(), f.getEntryPoint().toString(),
                    addr.subtract(f.getEntryPoint())));
            } else {
                println(String.format("0x%08x -> NO FUNCTION", a));
            }
        }
    }
}
