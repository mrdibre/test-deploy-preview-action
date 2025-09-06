import * as cdk from 'aws-cdk-lib';
import { Construct } from 'constructs';
import * as ecs from 'aws-cdk-lib/aws-ecs';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as elbv2 from 'aws-cdk-lib/aws-elasticloadbalancingv2';
import * as route53 from 'aws-cdk-lib/aws-route53';
import * as targets from 'aws-cdk-lib/aws-route53-targets';
import * as logs from 'aws-cdk-lib/aws-logs';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as ecr from 'aws-cdk-lib/aws-ecr';

export interface PreviewEnvProps extends cdk.StackProps {
  previewId: string;
  clusterArn: string;
  albListenerArn: string;
  hostedZoneId: string;
  domain: string;

  ecrImageFrontend: string; // repo:tag
  ecrImageBackend: string;

  cpu: number;
  memoryMiB: number;
  frontendPort: number;
  backendPort: number;
  apiPathPrefix: string;

  frontendHealthPath: string;
  backendHealthPath: string;

  subnetIdsCsv?: string;
  securityGroupIdsCsv?: string;
  assignPublicIp?: 'ENABLED' | 'DISABLED';
}

export class PreviewEnvStack extends cdk.Stack {
  constructor(scope: Construct, id: string, { env, ...props }: PreviewEnvProps) {
    super(scope, id, { env });

    // Hostname do preview
    const host = `${props.previewId}.${props.domain}`;

    // VPC
    const vpc = this.lookupVpc(props);

    // Cluster ECS existente
    const cluster = ecs.Cluster.fromClusterAttributes(this, 'Cluster', {
      clusterArn: props.clusterArn,
      vpc,
      clusterName: cdk.Fn.select(1, cdk.Fn.split('/', props.clusterArn))
    });

    // Importa listener + ALB
    const listener = elbv2.ApplicationListener.fromLookup(this, 'HttpsListener', {
      listenerArn: props.albListenerArn
    });

    const alb = elbv2.ApplicationLoadBalancer.fromLookup(this, 'ALB', {
      loadBalancerArn: "arn:aws:elasticloadbalancing:us-west-2:654654469708:loadbalancer/app/test-preview/d4f4384d24105f76",
    });

    // DNS
    const zone = route53.HostedZone.fromHostedZoneAttributes(this, 'Zone', {
      hostedZoneId: props.hostedZoneId,
      zoneName: props.domain
    });
    new route53.ARecord(this, 'Dns', {
      zone,
      recordName: host,
      target: route53.RecordTarget.fromAlias(new targets.LoadBalancerTarget(alb)),
      ttl: cdk.Duration.seconds(60)
    });

    // Logs
    const logGroup = new logs.LogGroup(this, 'Logs', {
      logGroupName: '/ecs/preview',
      retention: logs.RetentionDays.ONE_WEEK,
      removalPolicy: cdk.RemovalPolicy.DESTROY
    });

    // Roles
    const execRole = new iam.Role(this, 'ExecRole', {
      assumedBy: new iam.ServicePrincipal('ecs-tasks.amazonaws.com'),
      managedPolicies: [
        iam.ManagedPolicy.fromAwsManagedPolicyName('service-role/AmazonECSTaskExecutionRolePolicy')
      ]
    });
    const taskRole = new iam.Role(this, 'TaskRole', {
      assumedBy: new iam.ServicePrincipal('ecs-tasks.amazonaws.com')
    });

    // Imagens (aceita "repo:tag" ou "account.dkr.ecr.../repo:tag")
    const feImage = this.imageFromEcrSpec('FE', props.ecrImageFrontend);
    const beImage = this.imageFromEcrSpec('BE', props.ecrImageBackend);

    // Task definition com 2 containers
    const task = new ecs.FargateTaskDefinition(this, 'Task', {
      cpu: props.cpu,
      memoryLimitMiB: props.memoryMiB,
      executionRole: execRole,
      taskRole
    });

    const fe = task.addContainer('Frontend', {
      image: feImage,
      logging: ecs.LogDrivers.awsLogs({ logGroup, streamPrefix: `fe-${props.previewId}` }),
      essential: true
    });
    fe.addPortMappings({ 
      containerPort: props.frontendPort
    });

    const be = task.addContainer('Backend', {
      image: beImage,
      logging: ecs.LogDrivers.awsLogs({ logGroup, streamPrefix: `be-${props.previewId}` }),
      essential: true
    });
    be.addPortMappings({ 
      containerPort: props.backendPort
    });

    // Subnets & SGs
    const vpcSubnets = this.resolveSubnets(vpc, props.subnetIdsCsv);
    const sgroups = this.resolveSecurityGroups(props.securityGroupIdsCsv);

    // Service
    const svc = new ecs.FargateService(this, 'Service', {
      cluster,
      taskDefinition: task,
      desiredCount: 1,
      vpcSubnets,
      securityGroups: sgroups,
      assignPublicIp: props.assignPublicIp !== 'DISABLED',
      healthCheckGracePeriod: cdk.Duration.seconds(60)
    });

    // Target Groups
    const feTg = new elbv2.ApplicationTargetGroup(this, 'FeTg', {
      vpc,
      port: props.frontendPort,
      protocol: elbv2.ApplicationProtocol.HTTP,
      targetType: elbv2.TargetType.IP,
      healthCheck: { path: props.frontendHealthPath, healthyHttpCodes: '200' },
      deregistrationDelay: cdk.Duration.seconds(10)
    });
    feTg.addTarget(svc);

    const beTg = new elbv2.ApplicationTargetGroup(this, 'BeTg', {
      vpc,
      port: props.backendPort,
      protocol: elbv2.ApplicationProtocol.HTTP,
      targetType: elbv2.TargetType.IP,
      healthCheck: { path: props.backendHealthPath, healthyHttpCodes: '200' },
      deregistrationDelay: cdk.Duration.seconds(10)
    });
    beTg.addTarget(svc);

    // Prioridades estáveis (hash do previewId)
    const basePriority = 20000 + (this.stableHash(props.previewId) % 7000);

    // Regra FE: host
    new elbv2.ApplicationListenerRule(this, 'FeRule', {
      listener,
      priority: basePriority,
      conditions: [elbv2.ListenerCondition.hostHeaders([host])],
      targetGroups: [feTg]
    });

    // Regra BE: host + path
    if (props.apiPathPrefix && props.apiPathPrefix.trim().length > 0) {
      new elbv2.ApplicationListenerRule(this, 'BeRule', {
        listener,
        priority: basePriority + 500,
        conditions: [
          elbv2.ListenerCondition.hostHeaders([host]),
          elbv2.ListenerCondition.pathPatterns([props.apiPathPrefix])
        ],
        targetGroups: [beTg]
      });
    }

    new cdk.CfnOutput(this, 'PreviewUrl', { value: `https://${host}` });
  }

  private lookupVpc(props: PreviewEnvProps): ec2.IVpc {
    if (props.subnetIdsCsv && props.subnetIdsCsv.trim().length > 0) {
      // Quando subnets são passadas, apenas usamos a VPC de lookup (padrão)
    }
    return ec2.Vpc.fromLookup(this, 'Vpc', { isDefault: true });
  }

  private resolveSubnets(vpc: ec2.IVpc, csv?: string) {
    if (csv && csv.trim().length > 0) {
      const ids = csv.split(',').map(s => s.trim());
      return { subnets: ids.map((id, i) => ec2.Subnet.fromSubnetId(this, `Subnet${i}`, id)) };
    }
    return { subnetType: ec2.SubnetType.PUBLIC };
  }

  private resolveSecurityGroups(csv?: string) {
    if (csv && csv.trim().length > 0) {
      const ids = csv.split(',').map(s => s.trim());
      return ids.map((id, i) => ec2.SecurityGroup.fromSecurityGroupId(this, `Sg${i}`, id, { mutable: false }));
    }
    return [];
  }

  private imageFromEcrSpec(id: string, spec: string): ecs.ContainerImage {
    const [repoUri, tag] = spec.split(':');
    if (!repoUri || !tag) throw new Error(`Invalid image spec: ${spec} (expected repo:tag)`);
    const repoName = repoUri.split('/').pop()!;
    const repository = ecr.Repository.fromRepositoryName(this, `Repo${id}-${repoName}-${tag}`, repoName);
    return ecs.ContainerImage.fromEcrRepository(repository, tag);
  }

  private stableHash(s: string): number {
    let h = 0;
    for (let i = 0; i < s.length; i++) h = (h * 31 + s.charCodeAt(i)) >>> 0;
    return h;
  }
}
