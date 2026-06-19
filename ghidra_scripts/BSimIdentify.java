/* Identify which corpus libraries a binary embeds, using the BSim-foundry
 * signature DB. Read-only: queries every function in currentProgram against the BSim
 * server and prints a per-function best match plus a significance-weighted, per-library
 * rollup. Nothing in the program is modified.
 *
 * Args:
 *   [0] BSim URL          (default postgresql://user@localhost:5432/bsim)
 *   [1] min similarity    (default 0.0  — report everything)
 *   [2] min significance  (default 0.0)
 *
 * Run headless, e.g.:
 *   analyzeHeadless /tmp/proj tmp -import ./target.bin \
 *     -scriptPath ghidra_scripts -postScript BSimIdentify.java \
 *     postgresql://user@localhost:5432/bsim 0.7 20
 *
 * Attribution tip: rank libraries by the significance SUM, not raw similarity.
 * Tiny functions (significance < ~20) match many libraries at similarity 1.0 and
 * are noise; a genuinely embedded library shows a large significance sum.
 *
 * @category BSim
 */
import java.util.*;

import ghidra.app.script.GhidraScript;
import ghidra.features.bsim.gui.search.results.BSimMatchResult;
import ghidra.features.bsim.gui.search.results.ExecutableResult;
import ghidra.features.bsim.query.FunctionDatabase;
import ghidra.features.bsim.query.FunctionDatabase.ErrorCategory;
import ghidra.features.bsim.query.facade.*;
import ghidra.program.database.symbol.FunctionSymbol;
import ghidra.program.model.listing.*;

public class BSimIdentify extends GhidraScript {

	@Override
	protected void run() throws Exception {
		String[] a = getScriptArgs();
		String url = a.length > 0 ? a[0] : "postgresql://user@localhost:5432/bsim";
		double simMin = a.length > 1 ? Double.parseDouble(a[1]) : 0.0;
		double sigMin = a.length > 2 ? Double.parseDouble(a[2]) : 0.0;

		HashSet<FunctionSymbol> funcs = new HashSet<>();
		for (Function f : currentProgram.getFunctionManager().getFunctionsNoStubs(true)) {
			funcs.add((FunctionSymbol) f.getSymbol());
		}

		SimilarFunctionQueryService qs = new SimilarFunctionQueryService(currentProgram);
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
			info.setSignificanceThreshold(sigMin);
			SFQueryResult res = qs.querySimilarFunctions(info, null, monitor);
			List<BSimMatchResult> rows =
				BSimMatchResult.generate(res.getSimilarityResults(), currentProgram);

			// Best match per queried function.
			LinkedHashMap<String, BSimMatchResult> best = new LinkedHashMap<>();
			for (BSimMatchResult r : rows) {
				String q = r.getOriginalFunctionDescription().getFunctionName();
				BSimMatchResult cur = best.get(q);
				if (cur == null || r.getSimilarity() > cur.getSimilarity()) best.put(q, r);
			}

			println("");
			println("================ BSim identify: " + currentProgram.getName() + " ================");
			println("functions queried   : " + funcs.size());
			println("functions matched   : " + best.size());

			// Per-library rollup (merge arch / opt-level / per-.o fragments by library name).
			HashMap<String, double[]> roll = new HashMap<>(); // [sigSum, funcCount]
			TreeSet<ExecutableResult> exrows = ExecutableResult.generateFromMatchRows(rows);
			for (ExecutableResult er : exrows) {
				String lib = er.getExecutableRecord().getNameExec().replaceAll("@.*", "");
				double[] v = roll.computeIfAbsent(lib, k -> new double[2]);
				v[0] += er.getSignificanceSum();
				v[1] += er.getFunctionCount();
			}
			List<Map.Entry<String, double[]>> rl = new ArrayList<>(roll.entrySet());
			rl.sort((x, y) -> Double.compare(y.getValue()[0], x.getValue()[0]));
			println("--------------------------------------------------------");
			println("detected libraries (by significance sum — higher = real):");
			println(String.format("  %-16s %8s  %12s", "library", "funcs", "signifSum"));
			for (Map.Entry<String, double[]> e : rl) {
				println(String.format("  %-16s %8d  %12.0f",
					e.getKey(), (int) e.getValue()[1], e.getValue()[0]));
			}
			println("========================================================");
		}
		finally {
			qs.dispose();
		}
	}
}
