#!/usr/bin/env bash

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[x]${NC} $1"; exit 1; }
info() { echo -e "${BLUE}[i]${NC} $1"; }
section() { echo -e "\n${CYAN}══════════════════════════════════════${NC}"; echo -e "${CYAN}  $1${NC}"; echo -e "${CYAN}══════════════════════════════════════${NC}"; }

[[ $EUID -ne 0 ]] && err "Lance en root : sudo bash $0"


TOTAL_CORES=$(nproc)
LAST_CORE=$((TOTAL_CORES - 1))

if [[ $TOTAL_CORES -ge 16 ]]; then
    HOUSEKEEPING_CORES="0-3"
    MC_CORES="4-$((TOTAL_CORES / 2 - 1))"
    SCPSL_CORES="$((TOTAL_CORES / 2))-$LAST_CORE"
    GAME_CORES="4-$LAST_CORE"
elif [[ $TOTAL_CORES -ge 8 ]]; then
    HOUSEKEEPING_CORES="0-1"
    MC_CORES="2-$((TOTAL_CORES / 2 - 1))"
    SCPSL_CORES="$((TOTAL_CORES / 2))-$LAST_CORE"
    GAME_CORES="2-$LAST_CORE"
else
    HOUSEKEEPING_CORES="0"
    MC_CORES="1-$((TOTAL_CORES / 2))"
    SCPSL_CORES="$((TOTAL_CORES / 2 + 1))-$LAST_CORE"
    GAME_CORES="1-$LAST_CORE"
fi

TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
TOTAL_RAM_GB=$((TOTAL_RAM_KB / 1024 / 1024))
MC_RAM_GB=$((TOTAL_RAM_GB * 45 / 100))
SCPSL_RAM_GB=$((TOTAL_RAM_GB * 25 / 100))
HUGEPAGES_COUNT=$((MC_RAM_GB * 1024 / 2))

echo ""
echo "══════════════════════════════════════════════"
echo "   Optim Avancée — Minecraft + SCP:SL"
echo "══════════════════════════════════════════════"
info "CPUs détectés : $TOTAL_CORES cores"
info "RAM détectée  : ${TOTAL_RAM_GB}GB"
info "Housekeeping  : CPU $HOUSEKEEPING_CORES"
info "Minecraft     : CPU $MC_CORES (~${MC_RAM_GB}GB RAM)"
info "SCP:SL        : CPU $SCPSL_CORES (~${SCPSL_RAM_GB}GB RAM)"
info "HugePages     : $HUGEPAGES_COUNT pages × 2MB"
echo ""
read -rp "Continuer ? [o/N] " confirm
[[ "$confirm" =~ ^[oO]$ ]] || exit 0


section "1. HUGE PAGES (HugeTLBFS pour JVM)"

cat >> /etc/sysctl.d/99-server-optim.conf << EOF

vm.nr_hugepages = $HUGEPAGES_COUNT
vm.hugetlb_shm_group = 1000
kernel.shmmax = $((MC_RAM_GB * 1024 * 1024 * 1024))
kernel.shmall = $((MC_RAM_GB * 1024 * 1024 * 1024 / 4096))
EOF

sysctl -w vm.nr_hugepages="$HUGEPAGES_COUNT" >/dev/null
echo always > /sys/kernel/mm/transparent_hugepage/enabled
echo defer+madvise > /sys/kernel/mm/transparent_hugepage/defrag
echo 1 > /sys/kernel/mm/transparent_hugepage/khugepaged/defrag

cat > /etc/systemd/system/hugepages.service << EOF
[Unit]
Description=Configure HugePages
DefaultDependencies=no
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo $HUGEPAGES_COUNT > /proc/sys/vm/nr_hugepages'
ExecStart=/bin/sh -c 'echo always > /sys/kernel/mm/transparent_hugepage/enabled'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl enable hugepages.service
log "HugePages configurées : $HUGEPAGES_COUNT × 2MB = $((HUGEPAGES_COUNT * 2 / 1024))GB"


section "2. CPU ISOLATION (nohz_full + cgroups)"

GRUB_FILE="/etc/default/grub"
CURRENT_CMDLINE=$(grep "^GRUB_CMDLINE_LINUX=" "$GRUB_FILE" | sed 's/GRUB_CMDLINE_LINUX="\(.*\)"/\1/')

NEW_PARAMS="nohz=on nohz_full=$GAME_CORES rcu_nocbs=$GAME_CORES rcu_nocb_poll kthread_cpus=$HOUSEKEEPING_CORES irqaffinity=$HOUSEKEEPING_CORES nmi_watchdog=0 nosoftlockup nowatchdog mitigations=off threadirqs amd_pstate=active processor.max_cstate=1 idle=poll"

if ! grep -q "nohz_full" "$GRUB_FILE"; then
    sed -i "s|GRUB_CMDLINE_LINUX=\"\(.*\)\"|GRUB_CMDLINE_LINUX=\"\1 $NEW_PARAMS\"|" "$GRUB_FILE"
    update-grub 2>/dev/null || grub-mkconfig -o /boot/grub/grub.cfg
    log "Paramètres kernel ajoutés : nohz_full=$GAME_CORES"
else
    warn "nohz_full déjà configuré dans GRUB, skip"
fi

mkdir -p /etc/systemd/system/minecraft.slice.d
cat > /etc/systemd/system/minecraft.slice << EOF
[Unit]
Description=Minecraft Server Slice

[Slice]
CPUAccounting=yes
MemoryAccounting=yes
AllowedCPUs=$MC_CORES
MemoryMax=${MC_RAM_GB}G
EOF

mkdir -p /etc/systemd/system/scpsl.slice.d
cat > /etc/systemd/system/scpsl.slice << EOF
[Unit]
Description=SCP:SL Server Slice

[Slice]
CPUAccounting=yes
MemoryAccounting=yes
AllowedCPUs=$SCPSL_CORES
MemoryMax=${SCPSL_RAM_GB}G
EOF

systemctl daemon-reload
log "cgroups v2 : Minecraft=$MC_CORES | SCPSL=$SCPSL_CORES"


section "3. IRQ AFFINITY (tout sur housekeeping CPUs)"

cat > /usr/local/bin/pin-irqs.sh << EOF
#!/bin/bash
HK_MASK=\$(python3 -c "
cores='$HOUSEKEEPING_CORES'
import re
cpus = set()
for part in cores.split(','):
    if '-' in part:
        a, b = map(int, part.split('-'))
        cpus.update(range(a, b+1))
    else:
        cpus.add(int(part))
mask = sum(1 << c for c in cpus)
print(hex(mask)[2:])
")

for irq in /proc/irq/*/smp_affinity; do
    echo "\$HK_MASK" > "\$irq" 2>/dev/null || true
done

echo \$HK_MASK > /proc/irq/default_smp_affinity 2>/dev/null || true
EOF

chmod +x /usr/local/bin/pin-irqs.sh

cat > /etc/systemd/system/pin-irqs.service << 'EOF'
[Unit]
Description=Pin IRQs to housekeeping CPUs
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/pin-irqs.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl enable --now pin-irqs.service
log "IRQs épinglées sur CPUs $HOUSEKEEPING_CORES"


section "4. I/O SCHEDULER (NVMe optimisé)"

cat > /etc/udev/rules.d/60-ioscheduler.rules << 'EOF'
ACTION=="add|change", KERNEL=="nvme[0-9]*", ATTR{queue/scheduler}="none"
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="mq-deadline"
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="bfq"
EOF

for dev in /sys/block/nvme*; do
    [[ -d "$dev" ]] && echo none > "$dev/queue/scheduler" 2>/dev/null && info "NVMe scheduler=none : $dev" || true
done

for dev in /sys/block/sd*; do
    if [[ -f "$dev/queue/rotational" ]]; then
        rot=$(cat "$dev/queue/rotational")
        if [[ "$rot" == "0" ]]; then
            echo mq-deadline > "$dev/queue/scheduler" 2>/dev/null || true
        fi
    fi
done

for dev in /sys/block/nvme* /sys/block/sd*; do
    [[ -d "$dev" ]] || continue
    echo 0    > "$dev/queue/add_random"      2>/dev/null || true
    echo 2    > "$dev/queue/rq_affinity"     2>/dev/null || true
    echo 4096 > "$dev/queue/read_ahead_kb"   2>/dev/null || true
done

log "I/O schedulers configurés"


section "5. SYSCTL AVANCÉ (réseau + mémoire + kernel)"

cat > /etc/sysctl.d/99-server-optim.conf << EOF
vm.swappiness = 10
vm.dirty_ratio = 20
vm.dirty_background_ratio = 5
vm.vfs_cache_pressure = 50
vm.overcommit_memory = 1
vm.max_map_count = 2097152
vm.nr_hugepages = $HUGEPAGES_COUNT
vm.hugetlb_shm_group = 1000

kernel.sched_migration_cost_ns = 5000000
kernel.sched_autogroup_enabled = 0
kernel.numa_balancing = 0
kernel.perf_event_paranoid = -1
kernel.nmi_watchdog = 0
kernel.watchdog = 0
kernel.soft_watchdog = 0
kernel.hung_task_timeout_secs = 0
kernel.sched_min_granularity_ns = 10000000
kernel.sched_wakeup_granularity_ns = 15000000
kernel.sched_latency_ns = 80000000

fs.file-max = 4194304
fs.inotify.max_user_watches = 1048576
fs.inotify.max_user_instances = 1024
fs.aio-max-nr = 1048576

net.core.somaxconn = 65535
net.core.netdev_max_backlog = 250000
net.core.netdev_budget = 600
net.core.optmem_max = 67108864
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.ip_local_port_range = 1024 65535

net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_rmem = 4096 262144 33554432
net.ipv4.tcp_wmem = 4096 262144 33554432
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.core.rmem_default = 262144
net.core.wmem_default = 262144

net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192
net.core.busy_read = 50
net.core.busy_poll = 50
net.ipv4.tcp_notsent_lowat = 16384

net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_fack = 0
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_mtu_probing = 1

net.ipv6.conf.all.disable_ipv6 = 0
net.ipv6.conf.default.disable_ipv6 = 0
EOF

sysctl --system -q
log "Sysctl appliqué (TCP/UDP/VM/kernel)"


section "6. SYSTEMD SERVICES TEMPLATES"

MC_JAR_PATH="/opt/minecraft/server.jar"
SCPSL_PATH="/opt/scpsl/LocalAdmin"

cat > /etc/systemd/system/minecraft@.service << EOF
[Unit]
Description=Minecraft Server %i
After=network.target hugepages.service pin-irqs.service
Requires=hugepages.service

[Service]
Type=simple
User=minecraft
Group=minecraft
WorkingDirectory=/opt/minecraft/%i

Slice=minecraft.slice
CPUSchedulingPolicy=fifo
CPUSchedulingPriority=50
OOMScoreAdjust=-900
Nice=-15
LimitNOFILE=1048576
LimitNPROC=infinity
LimitMEMLOCK=infinity

Environment=MALLOC_ARENA_MAX=2
Environment=MALLOC_MMAP_THRESHOLD_=131072

ExecStart=/usr/bin/java \\
  -Xms${MC_RAM_GB}G -Xmx${MC_RAM_GB}G \\
  -XX:+UseG1GC \\
  -XX:+ParallelRefProcEnabled \\
  -XX:MaxGCPauseMillis=130 \\
  -XX:+UnlockExperimentalVMOptions \\
  -XX:+UnlockDiagnosticVMOptions \\
  -XX:+DisableExplicitGC \\
  -XX:+AlwaysPreTouch \\
  -XX:+UseHugeTLBFS \\
  -XX:LargePageSizeInBytes=2m \\
  -XX:G1NewSizePercent=28 \\
  -XX:G1MaxNewSizePercent=40 \\
  -XX:G1HeapRegionSize=16M \\
  -XX:G1ReservePercent=20 \\
  -XX:G1HeapWastePercent=5 \\
  -XX:G1MixedGCCountTarget=3 \\
  -XX:InitiatingHeapOccupancyPercent=10 \\
  -XX:G1MixedGCLiveThresholdPercent=90 \\
  -XX:G1RSetUpdatingPauseTimePercent=0 \\
  -XX:G1SATBBufferEnqueueingThresholdPercent=30 \\
  -XX:G1ConcMarkStepDurationMillis=5 \\
  -XX:G1ConcRSHotCardLimit=16 \\
  -XX:G1ConcRefinementServiceIntervalMillis=150 \\
  -XX:SurvivorRatio=32 \\
  -XX:MaxTenuringThreshold=1 \\
  -XX:+PerfDisableSharedMem \\
  -XX:+UseStringDeduplication \\
  -XX:+UseNUMA \\
  -XX:-DontCompileHugeMethods \\
  -XX:+UseTransparentHugePages \\
  -XX:ReservedCodeCacheSize=512m \\
  -XX:NonNMethodCodeHeapSize=12m \\
  -XX:ProfiledCodeHeapSize=194m \\
  -XX:NonProfiledCodeHeapSize=282m \\
  -XX:+SegmentedCodeCache \\
  -Dusing.aikars.flags=https://mcflags.emc.gs \\
  -Daikars.new.flags=true \\
  -jar $MC_JAR_PATH --nogui

Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF


cat > /etc/systemd/system/scpsl@.service << EOF
[Unit]
Description=SCP:SL Server %i
After=network.target pin-irqs.service

[Service]
Type=simple
User=scpsl
Group=scpsl
WorkingDirectory=/opt/scpsl/%i

Slice=scpsl.slice
CPUSchedulingPolicy=fifo
CPUSchedulingPriority=45
OOMScoreAdjust=-800
Nice=-10
LimitNOFILE=1048576
LimitNPROC=infinity

Environment=MALLOC_ARENA_MAX=4
Environment=DOTNET_GCHeapHardLimit=$((SCPSL_RAM_GB * 1024 * 1024 * 1024))
Environment=DOTNET_GCConserve=0
Environment=DOTNET_SYSTEM_NET_SOCKETS_INLINE_COMPLETIONS=1
Environment=DOTNET_ThreadPool_UnfairSemaphoreSpinLimit=70
Environment=LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libjemalloc.so.2

ExecStart=$SCPSL_PATH %i

Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
log "Services systemd créés : minecraft@.service et scpsl@.service"


section "7. ALLOCATEUR MÉMOIRE (jemalloc)"

apt-get install -y -qq libjemalloc2 libjemalloc-dev

JEMALLOC_PATH=$(find /usr -name "libjemalloc.so*" 2>/dev/null | head -1)
if [[ -n "$JEMALLOC_PATH" ]]; then
    log "jemalloc trouvé : $JEMALLOC_PATH"
else
    warn "jemalloc non trouvé, le service SCPSL utilisera glibc malloc"
fi


section "8. TMPFS POUR LOGS ET TEMP"

mkdir -p /opt/minecraft /opt/scpsl

cat >> /etc/fstab << 'EOF'

tmpfs /tmp                    tmpfs defaults,noatime,nosuid,mode=1777,size=4G  0 0
tmpfs /run/minecraft-tmp      tmpfs defaults,noatime,size=512M                 0 0
tmpfs /run/scpsl-tmp          tmpfs defaults,noatime,size=256M                 0 0
EOF

mkdir -p /run/minecraft-tmp /run/scpsl-tmp
mount /run/minecraft-tmp 2>/dev/null || true
mount /run/scpsl-tmp     2>/dev/null || true
log "tmpfs monté pour /tmp, logs Minecraft et SCPSL"


section "9. CPU GOVERNOR + C-STATES DÉSACTIVÉS"

for CPU in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    echo performance > "$CPU" 2>/dev/null || true
done

for CPU_ID in $(seq 0 "$LAST_CORE"); do
    CSTATE_PATH="/sys/devices/system/cpu/cpu${CPU_ID}/cpuidle"
    if [[ -d "$CSTATE_PATH" ]]; then
        for state in "$CSTATE_PATH"/state*/; do
            STATE_NAME=$(cat "${state}name" 2>/dev/null || echo "")
            if [[ "$STATE_NAME" != "POLL" && "$STATE_NAME" != "C0" && "$STATE_NAME" != "C1" ]]; then
                echo 1 > "${state}disable" 2>/dev/null || true
            fi
        done
    fi
done

cat > /etc/systemd/system/disable-cstates.service << 'EOF'
[Unit]
Description=Disable CPU C-States > C1
After=local-fs.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c '
for CPU_ID in $(seq 0 $(( $(nproc) - 1 )) ); do
  for state in /sys/devices/system/cpu/cpu${CPU_ID}/cpuidle/state*/; do
    name=$(cat ${state}name 2>/dev/null || echo "")
    case "$name" in
      POLL|C0|C1) ;;
      *) echo 1 > ${state}disable 2>/dev/null || true ;;
    esac
  done
done
for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
  echo performance > "$g" 2>/dev/null || true
done
'

[Install]
WantedBy=multi-user.target
EOF

systemctl enable --now disable-cstates.service
log "C-states > C1 désactivés, governor=performance"


section "10. RÉSEAU NIC AVANCÉ"

NIC=$(ip route | grep default | awk '{print $5}' | head -1)

if [[ -n "$NIC" ]]; then
    if command -v ethtool &>/dev/null; then
        ethtool -G "$NIC" rx 4096 tx 4096 2>/dev/null || true
        ethtool -K "$NIC" tso on gso on gro on 2>/dev/null || true
        ethtool -C "$NIC" rx-usecs 50 tx-usecs 50 2>/dev/null || true
        NIC_QUEUES=$(ethtool -l "$NIC" 2>/dev/null | grep "^Combined" | tail -1 | awk '{print $2}' || echo 1)
        MAX_QUEUES=$(nproc)
        TARGET_QUEUES=$([[ $NIC_QUEUES -gt $MAX_QUEUES ]] && echo $MAX_QUEUES || echo $NIC_QUEUES)
        ethtool -L "$NIC" combined "$TARGET_QUEUES" 2>/dev/null || true
        log "NIC $NIC : ring=4096, queues=$TARGET_QUEUES, coalescing tuné"
    else
        apt-get install -y -qq ethtool
        warn "ethtool installé, relance le script pour tuner le NIC"
    fi

    cat > /etc/systemd/system/nic-optim.service << EOF
[Unit]
Description=NIC optimization
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/ethtool -G $NIC rx 4096 tx 4096
ExecStart=/usr/sbin/ethtool -K $NIC tso on gso on gro on
ExecStart=/usr/sbin/ethtool -C $NIC rx-usecs 50 tx-usecs 50

[Install]
WantedBy=multi-user.target
EOF

    systemctl enable nic-optim.service
fi


section "11. CRÉATION USERS + RÉPERTOIRES"

useradd -r -s /bin/bash -d /opt/minecraft -m minecraft 2>/dev/null || warn "User minecraft existe déjà"
useradd -r -s /bin/bash -d /opt/scpsl     -m scpsl     2>/dev/null || warn "User scpsl existe déjà"

mkdir -p /opt/minecraft/default
mkdir -p /opt/scpsl/default

chown -R minecraft:minecraft /opt/minecraft
chown -R scpsl:scpsl         /opt/scpsl

usermod -aG minecraft minecraft
usermod -aG scpsl scpsl

if [[ -n "${SUDO_USER:-}" ]]; then
    usermod -aG minecraft "$SUDO_USER"
    usermod -aG scpsl     "$SUDO_USER"
    info "User $SUDO_USER ajouté aux groupes minecraft et scpsl"
fi

chmod 750 /opt/minecraft /opt/scpsl


section "12. RÉCAPITULATIF FINAL"

echo ""
log "Toutes les optimisations appliquées !"
echo ""
info "━━ RÉSUMÉ ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
info ""
info "  CPU Isolation"
info "    Housekeeping : CPU $HOUSEKEEPING_CORES (OS, IRQs, services)"
info "    Minecraft    : CPU $MC_CORES (isolés via nohz_full)"
info "    SCP:SL       : CPU $SCPSL_CORES (isolés via nohz_full)"
info ""
info "  Mémoire"
info "    HugePages    : $HUGEPAGES_COUNT × 2MB = $((HUGEPAGES_COUNT * 2 / 1024))GB (TLB JVM)"
info "    THP          : always + defer+madvise"
info "    Minecraft    : ${MC_RAM_GB}GB max (cgroup)"
info "    SCP:SL       : ${SCPSL_RAM_GB}GB max (cgroup)"
info ""
info "  JVM Minecraft"
info "    G1GC brucethemoose/Aikar + HugeTLBFS + NUMA + SegmentedCodeCache"
info ""
info "  SCP:SL"
info "    jemalloc + DOTNET tuning + Mirror networking UDP optimisé"
info ""
info "  Kernel"
info "    C-states > C1 désactivés, amd_pstate=active, watchdog off"
info "    nmi_watchdog=0 nosoftlockup nowatchdog"
info ""
info "  I/O"
info "    NVMe : scheduler=none, readahead=4096, rq_affinity=2"
info ""
info "  Réseau"
info "    BBR, busy_poll=50, UDP bufs, NIC ring=4096"
info ""
info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
info "Pour démarrer Minecraft  : systemctl start minecraft@default"
info "Pour démarrer SCP:SL     : systemctl start scpsl@default"
info "Pour activer au boot     : systemctl enable minecraft@default scpsl@default"
echo ""
warn "Place ton server.jar dans : /opt/minecraft/default/"
warn "Place LocalAdmin dans     : /opt/scpsl/default/"
echo ""
warn "REBOOT REQUIS pour nohz_full, C-states et HugePages"
echo ""
read -rp "Redémarrer maintenant ? [o/N] " r
[[ "$r" =~ ^[oO]$ ]] && reboot || true
