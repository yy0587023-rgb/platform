# ==============================================================================
# --- 完整 GPEDI.r (含系谱重构、近交计算、网络拓扑 JSON 及命令行接口) ---
# ==============================================================================

# 1. 加载必要的依赖包
options(repos = c(CRAN = "https://mirrors.tuna.tsinghua.edu.cn/CRAN/"))

required_packages <- c("sequoia", "dplyr", "openxlsx", "reshape2", "jsonlite")
for (pkg in required_packages) {
  if (!require(pkg, character.only = TRUE)) {
    tryCatch({
      install.packages(pkg)
    }, error = function(e) {
      message(paste("Warning: Could not install package", pkg))
    })
  }
  if (require(pkg, character.only = TRUE)) {
    library(pkg, character.only = TRUE)
  }
}


# 尝试加载 kinship2
if (!require("kinship2", character.only = TRUE)) {
  tryCatch({
    install.packages("kinship2")
  }, error = function(e) {
    message("标准安装 kinship2 失败，尝试安装特定兼容版本...")
  })
  
  if (!require("kinship2", character.only = TRUE)) {
    if (!require("remotes", character.only = TRUE)) install.packages("remotes")
    try(remotes::install_version("kinship2", version = "1.8.5", upgrade = "never", repos = "https://mirrors.tuna.tsinghua.edu.cn/CRAN/"))
  }
  if (require("kinship2", character.only = TRUE)) {
    library("kinship2", character.only = TRUE)
  }
}


# 辅助函数：读取/准备生活史数据
prepare_life_hist <- function(lh_file, ids) {
  if (!is.null(lh_file) && file.exists(lh_file)) {
    tryCatch({
      lh <- read.table(lh_file, header = TRUE, stringsAsFactors = FALSE)
      return(lh)
    }, error = function(e) {
      message("读取生活史文件失败，将忽略生活史先验数据。")
      return(NULL)
    })
  }
  return(NULL)
}


# ==============================================================================
# 2. 系谱重建与近交计算核心函数
# ==============================================================================

#' 系谱重建主函数
GPEDI.genealogy <- function(data, LifeHistData = NULL, pedoutput = 0, Tline = 0, out_dir = ".") {
  ids <- rownames(data)
  if (is.null(ids)) stop("data 必须有行名，作为个体 ID")
  if (anyDuplicated(ids)) stop("行名有重复，请保证每个个体唯一")
  if (length(ids) < 2) stop("个体数量不足，无法进行分析")

  pairs <- t(combn(ids, 2))
  pairs <- data.frame(ID1 = pairs[, 1], ID2 = pairs[, 2], stringsAsFactors = FALSE)

  GenoM <- as.matrix(data)
  rownames(GenoM) <- ids
  mode(GenoM) <- "numeric"

  message("正在计算亲缘关系...")
  PairL <- CalcPairLL(Pairs = pairs, GenoM = GenoM, Err = 1e-04, Plot = FALSE)
  
  PO <- PairL %>% filter(TopRel == "PO")
  fs_pairs <- PairL %>% filter(TopRel == "FS")
  hs_pairs <- PairL %>% filter(TopRel == "HS")

  # 1. 构建亲本 PO 映射表
  po_map <- vector("list", length(ids))
  names(po_map) <- ids
  if (nrow(PO) > 0) {
    for (i in seq_len(nrow(PO))) {
      id1 <- as.character(PO$ID1[i])
      id2 <- as.character(PO$ID2[i])
      po_map[[id1]] <- unique(c(po_map[[id1]], id2))
      po_map[[id2]] <- unique(c(po_map[[id2]], id1))
    }
  }

  p1_vec <- sapply(po_map, function(x) if (length(x) >= 1) x[1] else NA_character_)
  p2_vec <- sapply(po_map, function(x) if (length(x) >= 2) x[2] else NA_character_)

  # 2. 并查集计算家系树编号
  parent <- setNames(ids, ids)
  findp <- function(x) {
    root <- x
    while (parent[[root]] != root) {
      root <- parent[[root]]
    }
    curr <- x
    while (curr != root) {
      nxt <- parent[[curr]]
      parent[[curr]] <<- root
      curr <- nxt
    }
    root
  }
  unionp <- function(a, b) {
    ra <- findp(a)
    rb <- findp(b)
    if (ra != rb) parent[[rb]] <<- ra
  }

  group_edges <- rbind(
    PO %>% select(ID1, ID2),
    fs_pairs %>% select(ID1, ID2),
    hs_pairs %>% select(ID1, ID2)
  ) %>% distinct()

  if (nrow(group_edges) > 0) {
    for (i in seq_len(nrow(group_edges))) {
      a <- as.character(group_edges$ID1[i])
      b <- as.character(group_edges$ID2[i])
      if (a %in% ids && b %in% ids && !is.na(a) && !is.na(b) && a != "" && b != "") {
        unionp(a, b)
      }
    }
  }

  roots <- vapply(ids, findp, character(1))
  family_ids <- as.integer(factor(roots, levels = unique(roots)))

  # 3. 构建全同胞 (FS) 与半同胞 (HS) 列表
  build_rel_map <- function(df_rel) {
    rel_map <- vector("list", length(ids))
    names(rel_map) <- ids
    if (nrow(df_rel) > 0) {
      for (i in seq_len(nrow(df_rel))) {
        id1 <- as.character(df_rel$ID1[i])
        id2 <- as.character(df_rel$ID2[i])
        rel_map[[id1]] <- unique(c(rel_map[[id1]], id2))
        rel_map[[id2]] <- unique(c(rel_map[[id2]], id1))
      }
    }
    rel_map
  }

  fs_map <- build_rel_map(fs_pairs)
  hs_map <- build_rel_map(hs_pairs)

  # 4. 组装结果数据框
  ped_result <- data.frame(
    ID = ids,
    sire = p1_vec,
    dam = p2_vec,
    gender = NA_real_,
    familytrees = family_ids,
    p1 = p1_vec,
    p2 = p2_vec,
    FSnum = sapply(fs_map, length),
    FS = sapply(fs_map, function(x) if (length(x) == 0) NA_character_ else paste(x, collapse = ",")),
    HSnum = sapply(hs_map, length),
    HS = sapply(hs_map, function(x) if (length(x) == 0) NA_character_ else paste(x, collapse = ",")),
    stringsAsFactors = FALSE
  )

  # 5. 文件输出处理
  if (Tline == 1) {
    p1_edges <- ped_result[!is.na(ped_result$p1) & ped_result$p1 != "", c("ID", "p1")]
    colnames(p1_edges) <- c("ID", "parents")
    p2_edges <- ped_result[!is.na(ped_result$p2) & ped_result$p2 != "", c("ID", "p2")]
    colnames(p2_edges) <- c("ID", "parents")
    
    ped_TU <- rbind(p1_edges, p2_edges) %>% distinct()
    
    # 导出指定文件 3: Tline_reslut.csv
    write.csv(ped_TU, file.path(out_dir, "Tline_reslut.csv"), row.names = FALSE)
    
  }
  
  if (pedoutput == 1) {
    ped_out <- ped_result %>% select(ID, sire, dam, gender, familytrees, FSnum, FS, HSnum, HS)
    # 导出指定文件 1: pedigree_result.csv
    write.csv(ped_out, file.path(out_dir, "pedigree_result.csv"), row.names = FALSE)
  }
  
  return(ped_result)
}

#' 系谱统计输出函数
GPEDI.pedOUT <- function(data) {
  res <- list(
    total_count = nrow(data),
    sire_count = sum(!is.na(data$sire) & data$sire != "", na.rm = TRUE),
    dam_count = sum(!is.na(data$dam) & data$dam != "", na.rm = TRUE),
    unknown_count = sum(is.na(data$sire) & is.na(data$dam))
  )
  message("系谱统计完成")
  return(res)
}

#' 近交系数与世代计算函数
GPEDI.inbreeding <- function(data) {
  file <- data
  target3 <- na.omit(file[, 1])
  coi <- matrix(NA, length(target3), 3)
  
  for (m in seq_along(target3)) {
    target0 <- target3[m]
    j <- 0
    E <- target0
    visited <- character(0)
    while (!all(is.na(E))) {
      search.result <- file[file[, 1] %in% E, ]
      j <- j + 1 
      E <- unique(unlist(c(search.result[, 2], search.result[, 3])))
      E <- E[!is.na(E) & E != "NA" & E != ""]
      if (length(E) == 0 || all(E %in% visited)) break
      visited <- c(visited, E)
    }
    coi[m, 1] <- target0 
    coi[m, 2] <- j - 1 
  }
  
  coi <- coi[order(as.numeric(coi[, 2])), ]
  coi[coi[, 2] == "1", 3] <- 0
  coi_1 <- as.data.frame(coi, stringsAsFactors = FALSE)
  colnames(coi_1) <- c("ID", "gener", "inb")
  coi_1$gener <- as.numeric(coi_1$gener)
  coi_1$inb   <- as.numeric(coi_1$inb)
  
  MAX_gender <- max(coi_1$gener, na.rm = TRUE)
  if (is.na(MAX_gender) || MAX_gender < 2) return(coi_1)

  for (gener in 2:MAX_gender) {
    coi_3 <- coi_1[coi_1$gener == gener, ]
    if (nrow(coi_3) == 0) next
    
    for (o in 1:nrow(coi_3)) {
      target0 <- coi_3[o, 1]
      tar.s <- file[file[, 1] == target0, 2]
      tar.d <- file[file[, 1] == target0, 3]
      tar.all <- c(tar.s, tar.d)
      
      inbreed <- matrix(NA, gener, 2^(gener-1))
      inbreed[1, 1] <- target0
      
      for (i in 1:(gener-1)) {
        search.store <- inbreed[i, !is.na(inbreed[i, ])]
        search.num <- length(search.store)
        for (j in seq_len(search.num)) {
          if (search.store[j] %in% file[, 1]) {  
            search.result <- file[file[, 1] == search.store[j], ]
          } else {
            search.result <- matrix(NA, 1, 4)
          }
          inbreed[i+1, 2*j-1] <- search.result[1, 2]
          inbreed[i+1, 2*j]   <- search.result[1, 3]
        }
      }
      
      line <- list()
      mm <- 0
      for (i in 2:gener) {
        search.store <- as.character(inbreed[i, !is.na(inbreed[i, ])])
        dup.id <- unique(search.store[duplicated(search.store)])
        if (length(dup.id) > 0) {
          for (dup in seq_along(dup.id)) {
            dup.index <- grep(dup.id[dup], search.store)
            dup.num <- length(dup.index)
            for (m in 1:dup.num) {
              mm <- mm + 1
              line[[mm]] <- inbreed[i, dup.index[m]]
            }
            for (j in (i-1):2) {
              dup.index.2 <- ceiling(dup.index / 2)
              for (m in 1:dup.num) {
                line[[mm-m+1]] <- append(line[[mm-m+1]], inbreed[j, dup.index.2[m]])
              }
              dup.index <- dup.index.2
            }
          }
        }
      }
      
      n <- length(line)
      x <- 0
      if (n != 0) {
        first.id <- sapply(line, function(l) l[1])
        last.id  <- sapply(line, function(l) l[length(l)])
        table.matrix <- as.matrix(table(last.id))
        
        if (length(table.matrix) > 1) {
          min.id <- rownames(table.matrix)[1]
          max.id <- rownames(table.matrix)[2]
          min.num <- as.numeric(table.matrix[min.id, ])
          whole.line <- list()
          line.inb <- c()
          mm <- 0
          
          for (i in seq_len(min.num)) {
            min.index <- grep(min.id, last.id)[i]
            min.first <- line[[min.index]][1]
            last.id.2 <- last.id
            last.id.2[!first.id %in% min.first] <- NA
            last.id.2[min.index] <- NA
            max.index <- grep(max.id, last.id.2)
            
            for (k in max.index) {
              max.line <- line[[k]]
              the.line <- append(rev(max.line), line[[min.index]][-1])
              table.line <- as.matrix(table(the.line))
              Anumber <- max(table.line[, 1])
              if (the.line[1] %in% tar.all && the.line[length(the.line)] %in% tar.all) {   
                if (Anumber == 1) {
                  mm <- mm + 1
                  whole.line[[mm]] <- the.line
                  
                  ancestor_id <- min.id
                  ancestors.inb <- coi_1[coi_1$ID == ancestor_id, "inb"]
                  line.inb <- c(line.inb, if (length(ancestors.inb) > 0 && !is.na(ancestors.inb[1])) ancestors.inb[1] else 0)
                }
              } 
            }
          }
          if (length(whole.line) != 0) {
            for (i in seq_along(whole.line)) {
              T1 <- whole.line[[i]]
              x1 <- ifelse(!is.na(line.inb[i]), ((1/2)^length(T1)) * (1 + as.numeric(line.inb[i])), (1/2)^length(T1))
              x <- x + x1
            }
          }
        }
      }
      coi_1[coi_1$ID == target0, "inb"] <- x
    }
  }
  return(coi_1)
}

# ==============================================================================
# 3. 主流程入口与 JSON 网络拓扑导出
# ==============================================================================
cat("=== 启动 GPEDI 自动化计算流程 ===\n")

args <- commandArgs(trailingOnly = TRUE)
input_file <- if (length(args) > 0) args[1] else "sim_numeric.txt"
lh_file    <- if (length(args) > 2) args[3] else NULL

if (!file.exists(input_file)) {
  stop(paste0("错误：找不到输入的 SNP 数据文件 '", input_file, "'，请检查文件名和路径！"))
}


out_dir <- dirname(input_file)

cat("--> [1/4] 读取 SNP 输入文件:", input_file, "\n")
snp_data <- if (grepl("\\.xlsx$", input_file)) {
  openxlsx::read.xlsx(input_file, rowNames = TRUE)
} else if (grepl("\\.csv$", input_file)) {
  read.csv(input_file, rowNames = 1)
} else {
  read.table(input_file, header = TRUE, row.names = 1, check.names = FALSE)
}

life_hist_data <- prepare_life_hist(lh_file, rownames(snp_data))

cat("--> [2/4] 执行系谱重构并导出 pedigree_result.csv 与 Tline_reslut.csv ...\n")
ped_res <- GPEDI.genealogy(snp_data, LifeHistData = life_hist_data, pedoutput = 1, Tline = 1, out_dir = out_dir)

cat("--> [3/4] 执行群体统计与近交计算，导出 inbreeding_reslut.csv ...\n")
info_res <- GPEDI.pedOUT(ped_res)
inb_res  <- GPEDI.inbreeding(ped_res)


write.csv(inb_res, file.path(out_dir, "inbreeding_reslut.csv"), row.names = FALSE)

cat("--> [4/4] 导出 network_final.json 拓扑文件...\n")
nodes_list <- list()
edges_list <- list()
added_nodes <- c()

# 构建 JSON 节点与层级
gen_groups <- split(inb_res$ID, inb_res$gener)
for (g_str in names(gen_groups)) {
  g_num <- as.numeric(g_str)
  ids <- gen_groups[[g_str]]
  for (idx in seq_along(ids)) {
    id <- as.character(ids[idx])
    if (!is.na(id) && id != "") {
      nodes_list[[length(nodes_list) + 1]] <- list(
        data = list(id = id, label = id, generation = g_num),
        position = list(x = g_num * 180, y = (idx - 1) * 60)
      )
      added_nodes <- c(added_nodes, id)
    }
  }
}

sire_col_idx <- which(tolower(colnames(ped_res)) %in% c("sire", "p1"))
dam_col_idx  <- which(tolower(colnames(ped_res)) %in% c("dam", "p2"))
sire_col <- if (length(sire_col_idx) > 0) colnames(ped_res)[sire_col_idx[1]] else "sire"
dam_col  <- if (length(dam_col_idx) > 0)  colnames(ped_res)[dam_col_idx[1]]  else "dam"

for (i in 1:nrow(ped_res)) {
  child <- as.character(ped_res[i, "ID"])
  sire  <- as.character(ped_res[i, sire_col])
  dam   <- as.character(ped_res[i, dam_col])
  
  if (!is.na(sire) && sire != "" && sire != "NA") {
    if (!sire %in% added_nodes) {
      nodes_list[[length(nodes_list) + 1]] <- list(
        data = list(id = sire, label = sire, generation = 0),
        position = list(x = 0, y = length(nodes_list) * 60)
      )
      added_nodes <- c(added_nodes, sire)
    }
    edges_list[[length(edges_list) + 1]] <- list(
      data = list(source = sire, target = child, interaction = "sire")
    )
  }
  
  if (!is.na(dam) && dam != "" && dam != "NA") {
    if (!dam %in% added_nodes) {
      nodes_list[[length(nodes_list) + 1]] <- list(
        data = list(id = dam, label = dam, generation = 0),
        position = list(x = 0, y = length(nodes_list) * 60)
      )
      added_nodes <- c(added_nodes, dam)
    }
    edges_list[[length(edges_list) + 1]] <- list(
      data = list(source = dam, target = child, interaction = "dam")
    )
  }
}

network_json <- list(elements = list(nodes = nodes_list, edges = edges_list))

jsonlite::write_json(network_json, file.path(out_dir, "network_final.json"), auto_unbox = TRUE, pretty = TRUE)

cat("\n🎉 计算完成！已在输入文件所在目录下生成以下 4 个文件：\n")
cat(" 1.", file.path(out_dir, "pedigree_result.csv"), "\n")
cat(" 2.", file.path(out_dir, "inbreeding_reslut.csv"), "\n")
cat(" 3.", file.path(out_dir, "Tline_reslut.csv"), "\n")
cat(" 4.", file.path(out_dir, "network_final.json"), "\n")