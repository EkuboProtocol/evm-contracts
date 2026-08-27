// solhint ships no types. This is the sliver of its API that bin/check-complexity.ts
// uses -- see node_modules/solhint/lib/index.js.
declare module "solhint" {
  export interface SolhintMessage {
    line: number;
    column: number;
    severity: number;
    message: string;
    ruleId: string;
  }

  export interface SolhintReport {
    messages: SolhintMessage[];
  }

  export function processFile(path: string, config: unknown): SolhintReport;
}
