// The negative child models missing JSPI without depending on a V8 flag that newer Node releases remove.
Object.defineProperty(WebAssembly, 'Suspending', {value: undefined, configurable: true});
