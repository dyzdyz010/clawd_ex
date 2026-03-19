import { register } from 'node:module';
register(new URL('./esm-loader.js', import.meta.url));
