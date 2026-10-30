import * as fs from "fs";
import * as path from "path";
import { App } from "aws-cdk-lib";
import { KithFoodStack, KithFoodConfig } from "../lib/stack";

const cfgPath = path.join(__dirname, "..", "config.local.json");
if (!fs.existsSync(cfgPath)) throw new Error("aws/config.local.json がありません（config.example.json をコピー）");
const cfg: KithFoodConfig = JSON.parse(fs.readFileSync(cfgPath, "utf8"));

const app = new App();
new KithFoodStack(app, "KithFood", { env: { account: process.env.CDK_DEFAULT_ACCOUNT, region: cfg.region }, cfg });
