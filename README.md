# slm
SLM検証用のリポジトリ

## 1. SakanaAI/TinySwallow-1.5BをColabでファインチューニングする
まずは、ネット上の情報を参考に動作を確認<br>
[src/others/test.ipynb](src/others/test.ipynb)

## 2. vLLMによる推論サーバ構築

EC2であれば、下記の構成でデプロイできることを確認済み。

インスタンスタイプ：`g5.xlarge`

AMI : `Deep Learning OSS Nvidia Driver AMI GPU PyTorch 2.8 (Amazon Linux 2023)`

ディスク：`200GB`

実行コマンド（モデルは適宜変更）

```bash
docker run --runtime nvidia --gpus all \
    -v ~/.cache/huggingface:/root/.cache/huggingface \
    --env "HF_TOKEN=$HF_TOKEN" \
    -p 8000:8000 \
    --ipc=host \
    vllm/vllm-openai:latest \
    --model Qwen/Qwen3-0.6B
```

["参考"](https://docs.vllm.ai/en/latest/deployment/docker/ "参考")

### 2.1 TerraformでEC2構成を用意する

`src/tf` 配下にEKSクラスタと同じVPC上へGPU EC2を1台起動するTerraform定義を追加した。

## 3. EKSによる推論サーバ構築

### 3.1 TerraformでEKSクラスタを作成する。

下記のソースコードを実行、kubectlが実行できるところまで進める。

[src/tf ディレクトリはこちら](src/tf)

`terraform.tfvars` では `enable_ec2 = false`, `enable_eks = true` の状態で実行する。

主な重要箇所

アドオンには `vpc-cni` が必須で、`aws-ebs-csi-driver` は `aws_eks_addon.ebs_csi` で個別に適用する

```
  addons = {
    coredns                = {}
    eks-pod-identity-agent = {
      before_compute = true
    }
    kube-proxy = {}
    vpc-cni = {
      before_compute = true
      resolve_conflicts_on_create = "OVERWRITE"
      resolve_conflicts_on_update = "OVERWRITE"
    }
  }
```

```
resource "aws_eks_addon" "ebs_csi" {
  cluster_name                = module.eks[0].cluster_name
  addon_name                  = "aws-ebs-csi-driver"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  service_account_role_arn    = module.ebs_csi_irsa[0].iam_role_arn
}
```

起動テンプレートでインスタンスのカスタマイズを行う。ディスクが200GBほど必要、`http_put_response_hop_limit`はAWS LBコントローラを乗せるつもりなので2にしておく

`terraform plan`で起動テンプレートに設定が反映されていることを確認すること。（実行してダメでやり直すとか試行錯誤するとものすごく時間がかかる）

```
  # EKS Managed Node Group(s)
  eks_managed_node_groups = {
    example = {
      # Starting on 1.30, AL2023 is the default AMI type for EKS managed node groups
      ami_type       = "AL2023_x86_64_NVIDIA"
      instance_types = ["g5.xlarge"]

      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = 200
            volume_type           = "gp3"
            iops                  = 3000
            throughput            = 125
            encrypted             = true
            delete_on_termination = true
          }
        }
      }

      metadata_options = {
        http_endpoint               = "enabled"
        http_tokens                 = "required"
        http_put_response_hop_limit = 2
        http_protocol_ipv6          = "disabled"
        instance_metadata_tags      = "disabled"
      }

      min_size     = 1
      max_size     = 1
      desired_size = 1
    }
  }
```

### 3.2 NVIDIA device plugin for Kubernetes

NVIDIA device plugin for KubernetesをクラスターのDaemonsetとして適用する。

["NVIDIA device plugin for Kubernetes"](https://docs.aws.amazon.com/ja_jp/eks/latest/userguide/ml-eks-optimized-ami.html "NVIDIA device plugin for Kubernetes")

```bash
kubectl apply -f https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/v0.18.0/deployments/static/nvidia-device-plugin.yml
```

できたデーモンセットは下記の通り

```bash
% kubectl get daemonset -n kube-system
NAME                             DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR              AGE
aws-node                         1         1         1       1            1           <none>                     112m
ebs-csi-node                     1         1         1       1            1           kubernetes.io/os=linux     109m
ebs-csi-node-windows             0         0         0       0            0           kubernetes.io/os=windows   109m
eks-pod-identity-agent           1         1         1       1            1           <none>                     112m
kube-proxy                       1         1         1       1            1           <none>                     109m
nvidia-device-plugin-daemonset   1         1         1       1            1           <none>                     17m
```

### 3.3 StrageClass, PersistentVolumeClaim

下記のマニュフェストを適用する

[StrageClass, PersistentVolumeClaim](src/k8s/pvc.yaml)

### 3.4 Deployment

下記のマニュフェストを適用する

[Deployment](src/k8s/deployment.yaml)

### 3.5 Service, 経路確立

下記のマニュフェストを適用する

[Service](src/k8s/service.yaml)

ClusterIPにしているので、`kubectl port-forward`する

```bash
kubectl port-forward service/tinyswallow-1-5-b 8080:80
```

### 3.6 実行結果

別ターミナルで下記を実行、結果は支離滅裂だが無事応答が返ることを確認。

```bash
curl -s -X POST http://127.0.0.1:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
        "model": "SakanaAI/TinySwallow-1.5B",
        "messages": [
          {"role": "system", "content": "あなたは日本語で丁寧に回答するアシスタントです。"},
          {"role": "user", "content": "明日の天気は何ですか"}
        ],
        "max_tokens": 512,
        "temperature": 0.8,
        "top_p": 0.95
      }'
{"id":"chatcmpl-045337e7fb6343818bf5865197f3cbbf","object":"chat.completion","created":1763217730,"model":"SakanaAI/TinySwallow-1.5B","choices":[{"index":0,"message":{"role":"assistant","content":"あなたが明日に何を予定していますか？","refusal":null,"annotations":null,"audio":null,"function_call":null,"tool_calls":[],"reasoning_content":null},"logprobs":null,"finish_reason":"stop","stop_reason":null,"token_ids":null}],"service_tier":null,"system_fingerprint":null,"usage":{"prompt_tokens":35,"total_tokens":47,"completion_tokens":12,"prompt_tokens_details":null},"prompt_logprobs":null,"prompt_token_ids":null,"kv_transfer_params":null}
```