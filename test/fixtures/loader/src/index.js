export default {
	async fetch(request, env) {
		const worker = env.LOADER.get("hello", () => ({
			compatibilityDate: "2026-09-03",
			mainModule: "main.js",
			modules: {
				"main.js": "export default { fetch() { return new Response('hello from a dynamic worker'); } };",
			},
		}));
		return worker.getEntrypoint().fetch(request);
	},
};
