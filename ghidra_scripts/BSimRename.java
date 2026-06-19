/* Rename a binary's functions to their library names using the BSim-foundry
 * signature DB. For each function in currentProgram, queries the BSim server for the
 * closest matching library function and, when the match is confident enough, renames the function
 * and leaves an evidence plate comment + a "BSim" bookmark.
 *
 * This is the headless answer to a limitation of Ghidra's native BSim UI: because these
 * signatures keep no source programs (discarded during ingest), the GUI
 * "Apply Name / Apply Signature" buttons error out — they need the matched program to be
 * reachable. This script instead applies the name that BSim already stores, so no source
 * program is required. (Full prototype / data-type recovery is still out of scope.)
 *
 * Args:
 *   [0] BSim URL          (default postgresql://user@localhost:5432/bsim)
 *   [1] min similarity    (default 0.75)
 *   [2] min significance  (default 20.0  — raise to 40+ to cut false positives)
 *
 * Safety: only functions that currently have a DEFAULT name (FUN_xxxx) are renamed, so
 * existing symbols are never clobbered. Name collisions get an address suffix.
 *
 * Run headless, e.g.:
 *   analyzeHeadless ./out target -import ./target.bin \
 *     -scriptPath ghidra_scripts -postScript BSimRename.java \
 *     postgresql://user@localhost:5432/bsim 0.75 20
 * then open ./out/target.gpr in the Ghidra GUI to review (Window -> Functions / Bookmarks).
 *
 * @category BSim
 */
import java.util.*;

import ghidra.app.script.GhidraScript;
import ghidra.features.bsim.gui.search.results.BSimMatchResult;
import ghidra.features.bsim.query.FunctionDatabase;
import ghidra.features.bsim.query.FunctionDatabase.ErrorCategory;
import ghidra.features.bsim.query.facade.*;
import ghidra.program.database.symbol.FunctionSymbol;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.*;
import ghidra.program.model.symbol.SourceType;
import ghidra.util.exception.DuplicateNameException;

public class BSimRename extends GhidraScript {

	@Override
	protected void run() throws Exception {
		String[] a = getScriptArgs();
		String url = a.length > 0 ? a[0] : "postgresql://user@localhost:5432/bsim";
		double simMin = a.length > 1 ? Double.parseDouble(a[1]) : 0.75;
		double sigMin = a.length > 2 ? Double.parseDouble(a[2]) : 20.0;

		HashSet<FunctionSymbol> funcs = new HashSet<>();
		for (Function f : currentProgram.getFunctionManager().getFunctionsNoStubs(true)) {
			funcs.add((FunctionSymbol) f.getSymbol());
		}

		SimilarFunctionQueryService qs = new SimilarFunctionQueryService(currentProgram);
		int renamed = 0, skippedNamed = 0, belowThresh = 0, conflict = 0;
		try {
			qs.initializeDatabase(url);
			FunctionDatabase.BSimError err = qs.getLastError();
			if (err != null && err.category == ErrorCategory.Nodatabase) {
				println("ERROR: cannot connect to BSim DB: " + url);
				return;
			}

			SFQueryInfo info = new SFQueryInfo(funcs);
			info.setMaximumResults(1);
			info.setSimilarityThreshold(simMin);
			info.setSignificanceThreshold(0.0);
			SFQueryResult res = qs.querySimilarFunctions(info, null, monitor);
			List<BSimMatchResult> rows =
				BSimMatchResult.generate(res.getSimilarityResults(), currentProgram);

			// Best match per function address.
			HashMap<Long, BSimMatchResult> best = new HashMap<>();
			for (BSimMatchResult r : rows) {
				long addr = r.getOriginalFunctionDescription().getAddress();
				BSimMatchResult cur = best.get(addr);
				if (cur == null || r.getSimilarity() > cur.getSimilarity()) best.put(addr, r);
			}

			FunctionManager fm = currentProgram.getFunctionManager();
			Address base = currentProgram.getAddressFactory().getDefaultAddressSpace().getAddress(0);
			for (Map.Entry<Long, BSimMatchResult> e : best.entrySet()) {
				BSimMatchResult r = e.getValue();
				double sim = r.getSimilarity(), sig = r.getSignificance();
				if (sig < sigMin) { belowThresh++; continue; }

				Address addr = base.getNewAddress(e.getKey());
				Function fn = fm.getFunctionAt(addr);
				if (fn == null) continue;
				if (fn.getSymbol().getSource() != SourceType.DEFAULT) { skippedNamed++; continue; }

				String name = r.getMatchFunctionDescription().getFunctionName();
				String lib = r.getMatchFunctionDescription().getExecutableRecord().getNameExec();
				String note = String.format("BSim: %s  [%s]  sim=%.4f signif=%.1f", name, lib, sim, sig);
				try {
					fn.setName(name, SourceType.ANALYSIS);
				}
				catch (DuplicateNameException dup) {
					fn.setName(name + "_" + addr.toString(), SourceType.ANALYSIS);
					conflict++;
				}
				setPlateComment(addr, note);
				createBookmark(addr, "BSim", note);
				renamed++;
			}

			println("");
			println("============ BSim rename: " + currentProgram.getName() + " ============");
			println("thresholds              : similarity>=" + simMin + ", significance>=" + sigMin);
			println("functions queried       : " + funcs.size());
			println("renamed                 : " + renamed + "  (collisions suffixed: " + conflict + ")");
			println("skipped (already named) : " + skippedNamed);
			println("skipped (low signif)    : " + belowThresh);
			println("======================================================");
		}
		finally {
			qs.dispose();
		}
	}
}
