#!/bin/bash

# COLORS
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; PURPLE='\033[0;35m'; CYAN='\033[0;36m'
BOLD='\033[1m'; NC='\033[0m'

show_help() {
    echo -e "${RED}${BOLD}Elliot v1 - Bug Bounty Automation${NC}"
    echo -e "${YELLOW}Usage:${NC} $0 ${GREEN}-d${NC} DOMAIN ${YELLOW}[-a ASN] [-o DIR] [-nuclei-only] [-xss-only]${NC}"
    echo -e "${CYAN}Examples:${NC}"
    echo "  $0 -d testfire.net"
    echo "  $0 -d testfire.net -a 33070 -o results"
    echo "  $0 -d testfire.net -nuclei-only"
    exit 1
}

DOMAIN="" ASNS="" OUTPUT_DIR="" MODE="full"
while getopts "d:a:o:h-n-x:" opt; do
    case $opt in
        d) DOMAIN="$OPTARG";;
        a) ASNS="$OPTARG";;
        o) OUTPUT_DIR="$OPTARG";;
        h) show_help;;
        n) MODE="nuclei";;
        x) MODE="xss";;
    esac
done

[ -z "$DOMAIN" ] && show_help
OUTPUT_DIR=${OUTPUT_DIR:-"elliot_$DOMAIN"}
mkdir -p "$OUTPUT_DIR"

trap 'echo -e "${YELLOW}\n[!] Ctrl+C skipped...${NC}"; wait' SIGINT

# PERFECT BOX - EXACT 62 CHARS
clear
printf "${CYAN}╭─ ${BOLD}ELLIOT v1${NC} ${CYAN}"
printf '─%.0s' {1..50}
printf "╮\n"
printf "${CYAN}│                                                              │\n"
printf "${CYAN}├──────────────────────────────────────────────────────────────┤\n"
printf "${CYAN}│${NC} Target: ${GREEN}%s${NC} │Output: ${YELLOW}%s/ ${CYAN}│\n" "$DOMAIN" "$OUTPUT_DIR"
printf "${CYAN}│${NC} Mode: ${BLUE}%s${NC}│ ASNs: ${GREEN}%s ${CYAN}                                   │\n" "$MODE" "${ASNS:-none}"
printf "${CYAN}└──────────────────────────────────────────────────────────────┘\n"
echo

NUM_SUBS=0 NUM_LIVE=0 NUM_URLS=0 NUM_XSS=0 TOTAL_FINDINGS=0 NUM_SUBJACK=0

# ===========================================
# ALWAYS: SUBDOMAINS + SUBJACK (ALL MODES)
# ===========================================
echo -e "${BOLD}${GREEN}🔍 [1/7] SUBDOMAINS${NC}..."
echo -e "${CYAN}   🟢 subfinder...${NC}"
subfinder -d $DOMAIN -all -silent -o $OUTPUT_DIR/subfinder.txt 2>/dev/null

echo -e "${CYAN}   🟡 assetfinder...${NC}"
assetfinder --subs-only $DOMAIN 2>/dev/null | sort -u > $OUTPUT_DIR/assetfinder.txt

if [ -n "$ASNS" ]; then
    echo -e "${CYAN}   🔵 amass ASN...${NC}"
    > $OUTPUT_DIR/amass.txt
    for asn in $(echo $ASNS | tr ',' ' '); do
        amass enum -d $DOMAIN -asn $asn -config /dev/null -silent 2>/dev/null | \
        grep -oE "([a-zA-Z0-9_-]+\.)+$DOMAIN" | sort -u >> $OUTPUT_DIR/amass.txt
    done
    sort -u $OUTPUT_DIR/amass.txt -o $OUTPUT_DIR/amass.txt
fi

cat $OUTPUT_DIR/subfinder.txt $OUTPUT_DIR/assetfinder.txt $OUTPUT_DIR/amass.txt 2>/dev/null | \
sort -u | grep -oE "([a-zA-Z0-9_-]+\.)+$DOMAIN" > $OUTPUT_DIR/all_subs.txt

NUM_SUBS=$(wc -l < $OUTPUT_DIR/all_subs.txt | awk '{print $1}')
echo -e "\n   ${GREEN}✅ ${BOLD}$NUM_SUBS${NC} total ${BLUE}→${NC} $OUTPUT_DIR/all_subs.txt"

# ===========================================
# FIXED SUBJACK - SILENT + NO VERBOSE
# ===========================================
echo -e "\n${BOLD}${RED}🔒 [2/7] SUBTAKEOVER${NC}..."
> $OUTPUT_DIR/subjack_full.txt
> $OUTPUT_DIR/subjack.txt

# NO -v FLAG + PIPE TO SUPPRESS VERBOSE
subjack -w $OUTPUT_DIR/all_subs.txt -o $OUTPUT_DIR/subjack_full.txt 2>/dev/null >/dev/null 2>&1

# ONLY ACTUAL VULNERABILITIES
grep -iE "vulnerable|hijack|takeover" $OUTPUT_DIR/subjack_full.txt > $OUTPUT_DIR/subjack.txt 2>/dev/null

NUM_SUBJACK=$(wc -l < $OUTPUT_DIR/subjack.txt 2>/dev/null | awk '{print $1}' || echo 0)

if [ $NUM_SUBJACK -gt 0 ]; then
    echo -e "   ${RED}🚨 ${BOLD}$NUM_SUBJACK${NC} ${RED}VULNERABLE${NC} ${BLUE}→${NC} $OUTPUT_DIR/subjack.txt"
else
    echo -e "   ${GREEN}✅ ${BOLD}0${NC} vulnerable takeovers"
fi

# ===========================================
# LIVE + CRAWL (nuclei + xss + full)
# ===========================================
if [[ "$MODE" == "nuclei" || "$MODE" == "xss" || "$MODE" == "full" ]]; then
    echo -e "\n${BOLD}${GREEN}🌐 [3/7] LIVE CHECK${NC}..."
    cat $OUTPUT_DIR/all_subs.txt | httpx-toolkit -t 150 -silent -o $OUTPUT_DIR/live.txt 2>/dev/null
    NUM_LIVE=$(wc -l < $OUTPUT_DIR/live.txt 2>/dev/null | awk '{print $1}' || echo 0)
    echo -e "   ${GREEN}✅ ${BOLD}$NUM_LIVE${NC} live ${BLUE}→${NC} $OUTPUT_DIR/live.txt"

    echo -e "\n${BOLD}${PURPLE}🕷️ [4/7] CRAWLING${NC}..."
    {
        timeout 30 katana -list $OUTPUT_DIR/live.txt -silent -depth 3 -c 50 -o - 2>/dev/null || true
        cat $OUTPUT_DIR/all_subs.txt | sed 's~https\?://~~' | gau --threads 75 2>/dev/null || true
    } | sort -u | grep -E "^https?://" > $OUTPUT_DIR/all_urls.txt
    NUM_URLS=$(wc -l < $OUTPUT_DIR/all_urls.txt 2>/dev/null | awk '{print $1}' || echo 0)
    echo -e "   ${GREEN}✅ ${BOLD}$NUM_URLS${NC} URLs ${BLUE}→${NC} $OUTPUT_DIR/all_urls.txt"
fi

# ===========================================
# XSS (xss + full only)
# ===========================================
if [[ "$MODE" == "xss" || "$MODE" == "full" ]]; then
    echo -e "\n${BOLD}${CYAN}📝 [5/7] PARAMETERS${NC}..."
    cat $OUTPUT_DIR/all_urls.txt 2>/dev/null | grep -Eo '[?&][^=]+=' | sed 's/[?&]//' | sort -u > $OUTPUT_DIR/params.txt 2>/dev/null
    NUM_PARAMS=$(wc -l < $OUTPUT_DIR/params.txt 2>/dev/null | awk '{print $1}' || echo 0)
    echo -e "   ${GREEN}✅ ${BOLD}$NUM_PARAMS${NC} params"

    echo -e "\n${BOLD}${RED}🎯 [6/7] GXSS + DALFOX${NC}..."
    {
        cat $OUTPUT_DIR/live.txt 2>/dev/null | while read host; do
            cat $OUTPUT_DIR/params.txt 2>/dev/null | while read p; do 
                echo "$host?$p=reflectionXSS"
            done
        done
    } | sort -u | httpx-toolkit -mc 200,301,302,403 -t 100 -silent -o $OUTPUT_DIR/param_urls.txt 2>/dev/null

    cat $OUTPUT_DIR/param_urls.txt 2>/dev/null | xargs -P 30 -I {} sh -c '
        curl -s --max-time 2.5 "{}" 2>/dev/null | grep -q "reflectionXSS" && echo "{}"
    ' | tee $OUTPUT_DIR/reflected_urls.txt >/dev/null

    cat $OUTPUT_DIR/all_urls.txt $OUTPUT_DIR/reflected_urls.txt 2>/dev/null | \
    grep -E "\?.*=[^&\s]*" | \
    grep -vE "\.(css|js|png|jpg|jpeg|gif|svg|woff|ttf|ico|pdf|zip)$" | \
    sort -u > $OUTPUT_DIR/dalfox_input.txt 2>/dev/null

    if [ -s $OUTPUT_DIR/dalfox_input.txt ]; then
        dalfox file $OUTPUT_DIR/dalfox_input.txt -o $OUTPUT_DIR/xss_validated.txt 2>/dev/null
        NUM_XSS=$(wc -l < $OUTPUT_DIR/xss_validated.txt 2>/dev/null | awk '{print $1}' || echo 0)
    else
        NUM_XSS=0; touch $OUTPUT_DIR/xss_validated.txt
    fi
    echo -e "   ${GREEN}✅ ${BOLD}$NUM_XSS${NC} XSS ${BLUE}→${NC} $OUTPUT_DIR/xss_validated.txt"
fi

# ===========================================
# NUCLEI (nuclei + full only)
# ===========================================
if [[ "$MODE" == "nuclei" || "$MODE" == "full" ]]; then
    echo -e "\n${BOLD}${YELLOW}📋 PREP NUCLEI INPUT${NC}..."
    cat $OUTPUT_DIR/all_subs.txt ${OUTPUT_DIR}/all_urls.txt 2>/dev/null | sort -u > $OUTPUT_DIR/nuclei_input.txt
    NUM_NUCLEI_INPUT=$(wc -l < $OUTPUT_DIR/nuclei_input.txt 2>/dev/null | awk '{print $1}' || echo 0)
    echo -e "   ${GREEN}✅ ${BOLD}$NUM_NUCLEI_INPUT${NC} targets"

    echo -e "\n${BOLD}${RED}🚨 [7/7] NUCLEI${NC} ${YELLOW}(4 passes)${NC}..."
    NUCLEI_INPUT="$OUTPUT_DIR/nuclei_input.txt"

    echo -e "${PURPLE}   1️⃣ DAST...${NC}"
    nuclei -l $NUCLEI_INPUT -t ~/.local/nuclei-templates/dast/ -dast -o $OUTPUT_DIR/nuclei_dast.txt 2>/dev/null

    echo -e "${PURPLE}   2️⃣ CVEs...${NC}"
    nuclei -l $NUCLEI_INPUT -t ~/.local/nuclei-templates/http/cves/ -severity critical,high,medium -o $OUTPUT_DIR/nuclei_cves.txt 2>/dev/null

    echo -e "${PURPLE}   3️⃣ Exposure...${NC}"
    nuclei -l $NUCLEI_INPUT -tags exposure,misconfig,default-login,takeover -o $OUTPUT_DIR/nuclei_exposure.txt 2>/dev/null

    echo -e "${PURPLE}   4️⃣ FULL SCAN...${NC}"
    nuclei -l $NUCLEI_INPUT -severity critical,high,medium,low -o $OUTPUT_DIR/nuclei_all.txt 2>/dev/null

    TOTAL_FINDINGS=$(grep -c "\[critical\]\|\[high\]\|\[medium\]\|\[low\]\|\[info\]" $OUTPUT_DIR/nuclei_*.txt 2>/dev/null || echo 0)
    echo -e "   ${GREEN}✅ ${BOLD}$TOTAL_FINDINGS${NC} total findings"
fi

# ===========================================
# FINAL REPORT
# ===========================================
echo
printf "${CYAN}╭──────────────────────────────────────────────────────────────╮\n"
printf "${CYAN}│                                                              │\n"
printf "${CYAN}├──────────────────────────────────────────────────────────────┤\n"
printf "${CYAN}│${NC} %-12s ${GREEN}%4s${NC} │ ${YELLOW}%-25s ${NC}${CYAN}│${NC}\n" "Subs:" "$NUM_SUBS" "$OUTPUT_DIR/all_subs.txt"
printf "${CYAN}│${NC} %-12s ${RED}%4s${NC}  │ ${YELLOW}%-25s ${NC}${CYAN}│${NC}\n" "Takeover:" "$NUM_SUBJACK" "$OUTPUT_DIR/subjack.txt"
printf "${CYAN}│${NC} %-12s ${GREEN}%4s${NC} │ ${YELLOW}%-25s ${NC}${CYAN}│${NC}\n" "Live:" "$NUM_LIVE" "$OUTPUT_DIR/live.txt"
printf "${CYAN}│${NC} %-12s ${GREEN}%4s${NC} │ ${YELLOW}%-25s ${NC}${CYAN}│${NC}\n" "URLs:" "$NUM_URLS" "$OUTPUT_DIR/all_urls.txt"
printf "${CYAN}│${NC} %-12s ${RED}%4s${NC} │ ${YELLOW}%-25s ${NC}${CYAN}│${NC}\n" "XSS:" "$NUM_XSS" "$OUTPUT_DIR/xss_validated.txt"
printf "${CYAN}│${NC} %-12s ${PURPLE}%4s${NC} │ ${YELLOW}%-25s ${NC}${CYAN}│${NC}\n" "Nuclei:" "$TOTAL_FINDINGS" "$OUTPUT_DIR/nuclei_all.txt"
printf "${CYAN}└──────────────────────────────────────────────────────────────┘\n"

echo -e "\n${BOLD}${GREEN}✅ FINISHED!${NC} ${YELLOW}$OUTPUT_DIR/${NC}"
