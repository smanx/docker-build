#!/usr/bin/env python3
import os
import argparse
from huggingface_hub import HfApi, snapshot_download


def sync_dataset(source, target, hf_token):
    """同步一个 Hugging Face dataset 从源到目标"""
    print(f"开始同步: {source} -> {target}")
    
    api = HfApi(token=hf_token)
    
    # 下载源 dataset
    print("正在下载源 dataset...")
    local_dir = snapshot_download(
        repo_id=source,
        repo_type="dataset",
        token=hf_token
    )
    print(f"下载完成: {local_dir}")
    
    # 上传到目标 dataset
    print("正在上传到目标 dataset...")
    api.upload_folder(
        folder_path=local_dir,
        repo_id=target,
        repo_type="dataset",
        token=hf_token
    )
    print(f"✅ 同步完成: {source} -> {target}")


def main():
    parser = argparse.ArgumentParser(description="同步 Hugging Face Datasets")
    parser.add_argument("--source", required=True, help="源 dataset ID (例如: user/dataset)")
    parser.add_argument("--target", required=True, help="目标 dataset ID (例如: user/dataset-backup)")
    parser.add_argument("--token", required=False, help="Hugging Face access token (也可以通过 HF_TOKEN 环境变量设置)")
    
    args = parser.parse_args()
    
    # 优先使用命令行参数传入的 token，否则从环境变量获取
    hf_token = args.token or os.getenv("HF_TOKEN")
    if not hf_token:
        raise ValueError("必须通过 --token 参数或 HF_TOKEN 环境变量提供 Hugging Face access token")
    
    sync_dataset(args.source, args.target, hf_token)


if __name__ == "__main__":
    main()
