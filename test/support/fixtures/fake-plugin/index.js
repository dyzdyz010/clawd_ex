/**
 * Fake plugin for NodeBridge testing.
 * Registers one tool: "fake_echo" that echoes input back.
 */

export function register(api) {
  api.registerTool({
    name: 'fake_echo',
    description: 'Echoes the input message back',
    parameters: {
      type: 'object',
      properties: {
        message: { type: 'string', description: 'Message to echo' },
      },
      required: ['message'],
    },
    execute: async (params) => {
      return { echoed: params.message || '' };
    },
  });
}
