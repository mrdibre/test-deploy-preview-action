#!/usr/bin/env node
import * as cdk from 'aws-cdk-lib';
import { PreviewEnvStack } from '../lib/preview-env-stack';

const app = new cdk.App();

const previewId = app.node.getContext('previewId') as string;
const clusterArn = app.node.getContext('clusterArn') as string;
const albListenerArn = app.node.getContext('albListenerArn') as string;
const hostedZoneId = app.node.getContext('hostedZoneId') as string;
const domain = app.node.getContext('domain') as string;

const ecrImageFrontend = app.node.getContext('ecrImageFrontend') as string; // "account.dkr.ecr.region.amazonaws.com/repo:tag" ou "repo:tag"
const ecrImageBackend  = app.node.getContext('ecrImageBackend')  as string;

const cpu           = Number(app.node.tryGetContext('cpu') ?? 512);
const memoryMiB     = Number(app.node.tryGetContext('memoryMiB') ?? 1024);
const frontendPort  = Number(app.node.tryGetContext('frontendPort') ?? 80);
const backendPort   = Number(app.node.tryGetContext('backendPort') ?? 80);
const apiPathPrefix = (app.node.tryGetContext('apiPathPrefix') ?? '/api/*') as string;

const frontendHealthPath = (app.node.tryGetContext('frontendHealthPath') ?? '/') as string;
const backendHealthPath  = (app.node.tryGetContext('backendHealthPath')  ?? '/healthz') as string;

const subnetIdsCsv        = (app.node.tryGetContext('subnetIdsCsv') ?? '') as string;
const securityGroupIdsCsv = (app.node.tryGetContext('securityGroupIdsCsv') ?? '') as string;
const assignPublicIp      = (app.node.tryGetContext('assignPublicIp') ?? 'ENABLED') as 'ENABLED' | 'DISABLED';

new PreviewEnvStack(app, `Preview-${previewId}`, {
  previewId,
  clusterArn,
  albListenerArn,
  hostedZoneId,
  domain,
  ecrImageFrontend,
  ecrImageBackend,
  cpu,
  memoryMiB,
  frontendPort,
  backendPort,
  apiPathPrefix,
  frontendHealthPath,
  backendHealthPath,
  subnetIdsCsv,
  securityGroupIdsCsv,
  assignPublicIp,

  env: {
    account: "654654469708",
    region: "us-west-2"
  }
});
