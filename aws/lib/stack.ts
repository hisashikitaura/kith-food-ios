import * as path from "path";
import { Duration, RemovalPolicy, SecretValue, Stack, StackProps, CfnOutput } from "aws-cdk-lib";
import { Construct } from "constructs";
import * as s3 from "aws-cdk-lib/aws-s3";
import * as ddb from "aws-cdk-lib/aws-dynamodb";
import * as sqs from "aws-cdk-lib/aws-sqs";
import * as iam from "aws-cdk-lib/aws-iam";
import * as lambda from "aws-cdk-lib/aws-lambda";
import * as nodejs from "aws-cdk-lib/aws-lambda-nodejs";
import * as logs from "aws-cdk-lib/aws-logs";
import * as cognito from "aws-cdk-lib/aws-cognito";
import * as apigw from "aws-cdk-lib/aws-apigatewayv2";
import { HttpJwtAuthorizer } from "aws-cdk-lib/aws-apigatewayv2-authorizers";
import { HttpLambdaIntegration } from "aws-cdk-lib/aws-apigatewayv2-integrations";
import { SqsEventSource } from "aws-cdk-lib/aws-lambda-event-sources";
import * as budgets from "aws-cdk-lib/aws-budgets";

export interface KithFoodConfig {
  region: string;
  ownerEmail: string;
  ownerFirebaseUid: string;
  gcpServiceAccountUniqueId: string;
  gcpAudience: string;
  cognitoDomainPrefix: string;
  googleClientId?: string;
  googleClientSecretName?: string;
  /** Secrets Manager VersionId of the Google client secret. Pinning it makes `cdk deploy` detect rotations. */
  googleClientSecretVersionId?: string;
  bedrockModelId: string;
  budgetUsd?: number;
}

export class KithFoodStack extends Stack {
  constructor(scope: Construct, id: string, props: StackProps & { cfg: KithFoodConfig }) {
    super(scope, id, props);
    const cfg = props.cfg;

    // ---------- Storage ----------
    const bucket = new s3.Bucket(this, "Photos", {
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      encryption: s3.BucketEncryption.S3_MANAGED,
      enforceSSL: true,
      versioned: true,
      objectOwnership: s3.ObjectOwnership.BUCKET_OWNER_ENFORCED,
      lifecycleRules: [{ noncurrentVersionExpiration: Duration.days(30) }],
      removalPolicy: RemovalPolicy.RETAIN,
    });

    const table = new ddb.Table(this, "Table", {
      partitionKey: { name: "PK", type: ddb.AttributeType.STRING },
      sortKey: { name: "SK", type: ddb.AttributeType.STRING },
      billingMode: ddb.BillingMode.PAY_PER_REQUEST,
      pointInTimeRecoverySpecification: { pointInTimeRecoveryEnabled: true },
      timeToLiveAttribute: "ttl",
      removalPolicy: RemovalPolicy.RETAIN,
    });

    // ---------- Sync queue (FIFO = ordered per meal) ----------
    const dlq = new sqs.Queue(this, "SyncDLQ", {
      fifo: true,
      retentionPeriod: Duration.days(14),
      encryption: sqs.QueueEncryption.SQS_MANAGED,
      enforceSSL: true,
    });
    const queue = new sqs.Queue(this, "SyncQueue", {
      fifo: true,
      contentBasedDeduplication: false,
      visibilityTimeout: Duration.seconds(60),
      encryption: sqs.QueueEncryption.SQS_MANAGED,
      enforceSSL: true,
      deadLetterQueue: { queue: dlq, maxReceiveCount: 5 },
    });

    const fn = (name: string, entry: string, env: Record<string, string>, timeout = 15) => {
      const logGroup = new logs.LogGroup(this, `${name}Logs`, {
        retention: logs.RetentionDays.TWO_WEEKS,
        removalPolicy: RemovalPolicy.DESTROY,
      });
      return new nodejs.NodejsFunction(this, name, {
        entry: path.join(__dirname, "..", "lambda", entry),
        runtime: lambda.Runtime.NODEJS_22_X,
        architecture: lambda.Architecture.ARM_64,
        memorySize: 256,
        timeout: Duration.seconds(timeout),
        environment: env,
        logGroup,
        bundling: { externalModules: [], minify: true, target: "node22" },
      });
    };

    // ---------- Sync consumer ----------
    const syncFn = fn("SyncFn", "sync.ts", { TABLE: table.tableName }, 30);
    table.grantReadWriteData(syncFn);
    syncFn.addEventSource(new SqsEventSource(queue, { batchSize: 10, reportBatchItemFailures: true }));

    // ---------- GCP -> AWS federation (no keys) ----------
    // Google is a built-in web identity provider in IAM ("accounts.google.com").
    //  aud  = azp of the Google ID token (= service account unique id)
    //  oaud = aud of the token (audience requested by the Cloud Function)
    //  sub  = service account unique id
    const gcpRole = new iam.Role(this, "GcpSyncRole", {
      roleName: "kith-food-gcp-sync",
      maxSessionDuration: Duration.hours(1),
      assumedBy: new iam.WebIdentityPrincipal("accounts.google.com", {
        StringEquals: {
          "accounts.google.com:aud": cfg.gcpServiceAccountUniqueId,
          "accounts.google.com:oaud": cfg.gcpAudience,
          "accounts.google.com:sub": cfg.gcpServiceAccountUniqueId,
        },
      }),
      description: "Assumed by the kith-diary Cloud Function (Google ID token) to sync Kith Food meals",
    });
    gcpRole.addToPolicy(new iam.PolicyStatement({
      actions: ["sqs:SendMessage"],
      resources: [queue.queueArn],
    }));
    gcpRole.addToPolicy(new iam.PolicyStatement({
      actions: ["s3:PutObject", "s3:DeleteObject"],
      resources: [bucket.arnForObjects("users/*/meals/*")],
    }));

    // ---------- Cognito ----------
    const preSignUp = fn("PreSignUpFn", "presignup.ts", { OWNER_EMAIL: cfg.ownerEmail.toLowerCase() });
    const postConfirm = fn("PostConfirmFn", "postconfirm.ts", {
      OWNER_EMAIL: cfg.ownerEmail.toLowerCase(),
      OWNER_FIREBASE_UID: cfg.ownerFirebaseUid,
      TABLE: table.tableName,
    });
    table.grant(postConfirm, "dynamodb:PutItem");

    const pool = new cognito.UserPool(this, "Users", {
      userPoolName: "kith-food",
      selfSignUpEnabled: false,
      signInAliases: { email: true },
      accountRecovery: cognito.AccountRecovery.NONE,
      lambdaTriggers: { preSignUp, postConfirmation: postConfirm },
      removalPolicy: RemovalPolicy.RETAIN,
    });
    const domain = pool.addDomain("Domain", { cognitoDomain: { domainPrefix: cfg.cognitoDomainPrefix } });

    const providers: cognito.UserPoolClientIdentityProvider[] = [];
    let googleIdp: cognito.UserPoolIdentityProviderGoogle | undefined;
    if (cfg.googleClientId) {
      googleIdp = new cognito.UserPoolIdentityProviderGoogle(this, "Google", {
        userPool: pool,
        clientId: cfg.googleClientId,
        clientSecretValue: SecretValue.secretsManager(cfg.googleClientSecretName ?? "kith-food/google-oauth-client-secret",
          cfg.googleClientSecretVersionId ? { versionId: cfg.googleClientSecretVersionId } : {}),
        scopes: ["openid", "email", "profile"],
        attributeMapping: {
          email: cognito.ProviderAttribute.GOOGLE_EMAIL,
        },
      });
      providers.push(cognito.UserPoolClientIdentityProvider.GOOGLE);
    } else {
      providers.push(cognito.UserPoolClientIdentityProvider.COGNITO);
    }
    const client = pool.addClient("IosClient", {
      generateSecret: false,
      preventUserExistenceErrors: true,
      supportedIdentityProviders: providers,
      accessTokenValidity: Duration.hours(1),
      idTokenValidity: Duration.hours(1),
      refreshTokenValidity: Duration.days(30),
      oAuth: {
        flows: { authorizationCodeGrant: true },
        scopes: [cognito.OAuthScope.OPENID, cognito.OAuthScope.EMAIL, cognito.OAuthScope.PROFILE],
        callbackUrls: ["kithfood://auth"],
        logoutUrls: ["kithfood://signout"],
      },
    });
    if (googleIdp) client.node.addDependency(googleIdp);

    // ---------- API ----------
    const apiFn = fn("ApiFn", "api.ts", {
      TABLE: table.tableName,
      BUCKET: bucket.bucketName,
      MODEL_ID: cfg.bedrockModelId,
      CLIENT_ID: client.userPoolClientId,
    }, 60);
    apiFn.addToRolePolicy(new iam.PolicyStatement({
      actions: ["dynamodb:Query", "dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem"],
      resources: [table.tableArn],
    }));
    apiFn.addToRolePolicy(new iam.PolicyStatement({
      actions: ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
      resources: [bucket.arnForObjects("users/*/meals/*")],
    }));
    apiFn.addToRolePolicy(new iam.PolicyStatement({
      actions: ["bedrock:InvokeModel", "bedrock:Converse"],
      resources: [
        `arn:aws:bedrock:*::foundation-model/${cfg.bedrockModelId.replace(/^(jp|apac|global|us|eu)\./, "")}`,
        `arn:aws:bedrock:${this.region}:${this.account}:inference-profile/${cfg.bedrockModelId}`,
      ],
    }));

    const authorizer = new HttpJwtAuthorizer("Cognito",
      `https://cognito-idp.${this.region}.amazonaws.com/${pool.userPoolId}`,
      { jwtAudience: [client.userPoolClientId] });
    const api = new apigw.HttpApi(this, "Api", {
      apiName: "kith-food",
      defaultAuthorizer: authorizer,
      createDefaultStage: false,
    });
    new apigw.HttpStage(this, "Stage", {
      httpApi: api,
      stageName: "$default",
      autoDeploy: true,
      throttle: { rateLimit: 10, burstLimit: 20 },
    });
    const integ = new HttpLambdaIntegration("ApiInteg", apiFn);
    const M = apigw.HttpMethod;
    api.addRoutes({ path: "/meals", methods: [M.GET, M.POST], integration: integ });
    api.addRoutes({ path: "/meals/{id}", methods: [M.PATCH, M.DELETE], integration: integ });
    api.addRoutes({ path: "/meals/{id}/photo", methods: [M.GET], integration: integ });
    api.addRoutes({ path: "/meals/{id}/upload-url", methods: [M.POST], integration: integ });
    api.addRoutes({ path: "/meals/{id}/analyze", methods: [M.POST], integration: integ });

    // ---------- Budget ----------
    new budgets.CfnBudget(this, "Budget", {
      budget: {
        budgetName: "kith-food-monthly",
        budgetType: "COST",
        timeUnit: "MONTHLY",
        budgetLimit: { amount: cfg.budgetUsd ?? 10, unit: "USD" },
      },
      notificationsWithSubscribers: [
        {
          notification: { notificationType: "ACTUAL", comparisonOperator: "GREATER_THAN", threshold: 80, thresholdType: "PERCENTAGE" },
          subscribers: [{ subscriptionType: "EMAIL", address: cfg.ownerEmail }],
        },
        {
          notification: { notificationType: "FORECASTED", comparisonOperator: "GREATER_THAN", threshold: 100, thresholdType: "PERCENTAGE" },
          subscribers: [{ subscriptionType: "EMAIL", address: cfg.ownerEmail }],
        },
      ],
    });

    new CfnOutput(this, "ApiUrl", { value: api.apiEndpoint });
    new CfnOutput(this, "BucketName", { value: bucket.bucketName });
    new CfnOutput(this, "TableName", { value: table.tableName });
    new CfnOutput(this, "QueueUrl", { value: queue.queueUrl });
    new CfnOutput(this, "DlqUrl", { value: dlq.queueUrl });
    new CfnOutput(this, "GcpSyncRoleArn", { value: gcpRole.roleArn });
    new CfnOutput(this, "UserPoolId", { value: pool.userPoolId });
    new CfnOutput(this, "UserPoolClientId", { value: client.userPoolClientId });
    new CfnOutput(this, "CognitoDomain", { value: `${domain.domainName}.auth.${this.region}.amazoncognito.com` });
    new CfnOutput(this, "GoogleRedirectUri", {
      value: `https://${domain.domainName}.auth.${this.region}.amazoncognito.com/oauth2/idpresponse`,
    });
  }
}
