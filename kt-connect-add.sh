#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

CONFIG_FILE="/etc/sing-box/config.json"
TEMP_SB_CONFIG="/tmp/config.json.tmp.$$" # Temporary file for sing-box config

# Get the directory where the script is located.
# Based on your new plan, this directory is ~/ipset
SCRIPT_DIR="$(dirname "$0")"
# The ipset config file is now directly in the SCRIPT_DIR
IPSET_FILE="$SCRIPT_DIR/yuanxin.json"
TEMP_IPSET_CONFIG="/tmp/yuanxin.json.tmp.$$" # Temporary file for ipset config


# Clean up temporary files on exit (even if errors occur)
trap 'rm -f "$TEMP_SB_CONFIG" "$TEMP_IPSET_CONFIG"' EXIT

# --- Input ---
read -p "输入医院名称 (例如，南京市儿童医院): " HOSPITAL_NAME
read -p "输入代理服务器 IP (默认: 192.168.48.153): " PROXY_IP
# Check if PROXY_IP is empty and set default if needed
if [ -z "$PROXY_IP" ]; then
    PROXY_IP="192.168.48.153"
fi

read -p "输入代理端口 (例如，21234): " PROXY_PORT
read -p "输入 IP CIDR(s) (逗号分隔, 例如，10.9.9.0/24,10.9.6.0/24): " IP_CIDRS

# --- Basic Validation ---
if [ -z "$HOSPITAL_NAME" ] || [ -z "$PROXY_IP" ] || [ -z "$PROXY_PORT" ] || [ -z "$IP_CIDRS" ]; then
    echo "错误: 部分输入项为空。"
    exit 1
fi

# --- Prepare Data ---
echo "--- 准备修改配置 ---"
echo "医院名称: $HOSPITAL_NAME"
echo "代理 IP: $PROXY_IP"
echo "代理端口: $PROXY_PORT"
echo "IP CIDRs: $IP_CIDRS"

# Format IP_CIDRS into a JSON array string using jq
echo "DEBUG: Attempting jq command for IP_CIDR_JSON_ARRAY using gsub..."
# Pass the raw input string to jq, split, use gsub to trim, and filter.
# Use -R -n with --arg to correctly handle the single input string.
# Use gsub to trim as trim might not be available in older jq versions
IP_CIDR_JSON_ARRAY=$(jq -R -n --arg ip_string "$IP_CIDRS" \
  '$ip_string | split(",") | map(select(. != "") | gsub("^\\s+|\\s+$"; ""))')

# Check if jq command itself failed or produced empty output
if [ $? -ne 0 ] || [ -z "$IP_CIDR_JSON_ARRAY" ]; then
    echo "错误: IP CIDR 格式无效或 jq 处理失败。jq命令可能出错或输出为空。"
    exit 1
fi

echo "DEBUG: jq command for IP_CIDR_JSON_ARRAY finished."
echo "DEBUG: IP_CIDR_JSON_ARRAY value is: '$IP_CIDR_JSON_ARRAY'"

echo "IP CIDRs (JSON格式): $IP_CIDR_JSON_ARRAY"

# --- JQ Modification (Sing-box Config) ---
echo "正在读取和修改 sing-box 配置文件: $CONFIG_FILE ..."

# Fixed insertion index for testing (after initial standard rules)
# This is a simplified approach. For production, you need to re-implement
# the logic to find the correct insertion point in your original script.
INSERT_INDEX=3 # Example: Insert after the first 3 rules (sniff, hijack-dns, resolve)

echo "DEBUG: Using INSERT_INDEX: $INSERT_INDEX"

echo "DEBUG: Attempting main jq modification for sing-box config..."
if ! jq \
  --arg hospital_name "$HOSPITAL_NAME" \
  --arg proxy_ip "$PROXY_IP" \
  --argjson proxy_port "$PROXY_PORT" \
  --argjson ip_cidr_array "$IP_CIDR_JSON_ARRAY" \
  --argjson insert_index "$INSERT_INDEX" \
  '
  # Add the new outbound definition
  (.outbounds) += [
    {
      "type": "socks",
      "tag": $hospital_name,
      "server": $proxy_ip,
      "server_port": $proxy_port,
      "version": "5",
      "network": "tcp"
    }
  ]
  # Pipe the result to the next modification step
  |
  # Insert the new route rule at the specified index
  (.route.rules) |= (
    # Take elements before the index
    .[:$insert_index] +
    # Add the new rule as a single-element array
    [
      {
        "ip_cidr": $ip_cidr_array, # $ip_cidr_array is already a jq array
        "outbound": $hospital_name
      }
    ] +
    # Add elements from the index onwards
    .[$insert_index:]
  )
  ' "$CONFIG_FILE" > "$TEMP_SB_CONFIG"; then

  echo "错误: 修改 sing-box 配置的 jq 命令执行失败。请检查上面的 jq 错误信息。"
  exit 1
fi
echo "DEBUG: Main jq modification for sing-box config finished."


# --- Replace Sing-box Config File ---
echo "备份原 sing-box 文件到 ${CONFIG_FILE}.bak"
# Use sudo cp and check its success
if ! sudo cp "$CONFIG_FILE" "${CONFIG_FILE}.bak"; then
    echo "错误: 备份 sing-box 配置文件失败。"
    exit 1
fi

echo "用修改后的 sing-box 配置替换原文件..."
# Use sudo mv and check its success
# --- FIX --- Removed the duplicate 'then' here
if ! sudo mv "$TEMP_SB_CONFIG" "$CONFIG_FILE"; then
    echo "错误: 替换 sing-box 配置文件失败。"
    exit 1
fi

echo "sing-box 配置修改成功！"


# --- JQ Modification (IPset Config) ---
echo "正在读取和修改 ipset 配置文件: $IPSET_FILE ..."

# Check if ipset file exists
if [ ! -f "$IPSET_FILE" ]; then
    echo "错误: ipset 配置文件未找到: $IPSET_FILE"
    # Updated message for the new file location
    echo "请确保脚本在包含 yuanxin.json 文件的目录下运行。"
    exit 1
fi

echo "DEBUG: Attempting jq modification for ipset config..."
# Read the ipset file, append the new CIDRs to the first rule's ip_cidr array
if ! jq --argjson new_cidrs "$IP_CIDR_JSON_ARRAY" \
  '.rules[0].ip_cidr += $new_cidrs' "$IPSET_FILE" > "$TEMP_IPSET_CONFIG"; then

  echo "错误: 修改 ipset 配置 (${IPSET_FILE}) 的 jq 命令执行失败。请检查上面的 jq 错误信息。"
  exit 1
fi
echo "DEBUG: jq modification for ipset config finished."

# --- Replace IPset Config File ---
# Optional: backup ipset file if needed, skipped for brevity here
echo "用修改后的 ipset 配置替换原文件..."
if ! mv "$TEMP_IPSET_CONFIG" "$IPSET_FILE"; then
    echo "错误: 替换 ipset 配置文件 (${IPSET_FILE}) 失败。"
    exit 1
fi

echo "ipset 配置修改成功！"

# --- Git Operations ---
echo "正在处理 Git 提交..."

# Navigate to the script directory to perform git operations
# This directory now contains yuanxin.json and is the git repo root according to the user's plan
pushd "$SCRIPT_DIR" > /dev/null # pushd and suppress output

# Check if it's a git repository
if [ ! -d .git ]; then
    echo "错误: 当前目录 ($SCRIPT_DIR) 不是一个 Git 仓库。"
    # Updated message based on new layout
    echo "请在包含 .git 文件夹和 yuanxin.json 文件的目录下运行脚本。"
    popd > /dev/null # Restore directory
    exit 1
fi

# The file to add is now just "yuanxin.json" relative to SCRIPT_DIR
IP_SET_GIT_FILE="yuanxin.json"

echo "暂存 ipset 文件改动..."
if ! git add "$IP_SET_GIT_FILE"; then
    echo "错误: git add $IP_SET_GIT_FILE 失败。"
    popd > /dev/null # Restore directory
    exit 1
fi

# Check if there are any changes staged for commit
if git diff --cached --quiet "$IP_SET_GIT_FILE"; then
    echo "ipset 文件没有检测到实际改动，跳过 Git 提交。"
else
    echo "提交 ipset 文件改动..."
    # Construct a simple commit message including hospital name
    COMMIT_MSG="Update yuanxin.json with new CIDRs for ${HOSPITAL_NAME}" # Changed message slightly
    if ! git commit -m "$COMMIT_MSG"; then
        echo "错误: git commit 失败。"
        # Note: commit might fail if user.name/user.email not configured
        popd > /dev/null # Restore directory
        exit 1
    fi
    echo "Git 提交成功。"
fi

# Return to the original directory
popd > /dev/null # Restore directory
echo "Git 处理完成。"


# --- Configuration Check (Sing-box) ---
echo "正在检查 sing-box 配置..."
# Use sudo sing-box check and check its success
if sudo sing-box check -c "$CONFIG_FILE"; then
  echo "sing-box 配置检查通过。"

  # --- Restart Service ---
  echo "正在重启 sing-box 服务..."
  # Use sudo systemctl restart and check its success
  if sudo systemctl restart sing-box; then
    echo "sing-box 服务重启成功。"
  else
    echo "错误: sing-box 服务重启失败。"
    # Configuration is OK, but restart failed. User needs manual intervention.
    exit 1
  fi
else
  # Configuration check failed. Original config is backed up.
  echo "错误: sing-box 配置检查失败。请手动检查配置文件: $CONFIG_FILE"
  echo "详细错误请查看上面的 sing-box check 输出。"
  echo "原文件已备份到 ${CONFIG_FILE}.bak"
  exit 1
fi

# If we reached here, everything was successful
echo "所有配置修改和 Git 操作完成，sing-box 服务已重启。"
