import { FastifyInstance, FastifyPluginOptions } from "fastify";

export default async function routes(
  fastify: FastifyInstance,
  _opts: FastifyPluginOptions
) {
  fastify.get("/", async () => {
    return { message: "API root" };
  });
}
