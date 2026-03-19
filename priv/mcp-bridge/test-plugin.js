/**
 * Simple test plugin for validating the MCP bridge.
 *
 * Registers two tools:
 *   - echo: returns the input text
 *   - add:  sums two numbers
 */
export default {
  register(api) {
    api.logger.info('Test plugin registering tools...');

    // Simple string-returning tool
    api.registerTool({
      name: 'echo',
      description: 'Echo back the input text',
      parameters: {
        type: 'object',
        properties: {
          text: { type: 'string', description: 'Text to echo back' },
        },
      },
      execute: async (params) => {
        return params.text || 'empty';
      },
    });

    // Object-returning tool
    api.registerTool({
      name: 'add',
      description: 'Add two numbers together',
      parameters: {
        type: 'object',
        properties: {
          a: { type: 'number', description: 'First number' },
          b: { type: 'number', description: 'Second number' },
        },
        required: ['a', 'b'],
      },
      execute: async (params) => {
        const sum = (params.a || 0) + (params.b || 0);
        return { result: sum };
      },
    });

    // Tool that throws an error (for error-handling tests)
    api.registerTool({
      name: 'fail',
      description: 'Always fails (for testing error handling)',
      parameters: { type: 'object', properties: {} },
      execute: async () => {
        throw new Error('Intentional failure for testing');
      },
    });

    api.logger.info('Test plugin registered 3 tools');
  },
};
