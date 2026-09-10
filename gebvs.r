suppressPackageStartupMessages({
  library(BGLR)
  library(data.table)
  library(foreach)
  library(doParallel)
})

# ----------------------------- 配置区域 ------------------------------------
BASE_PATH <- "/app/yak/server/uploadPath/upload/yak"
GAPIT_FUN <- file.path(BASE_PATH, "gapit_functions.txt")   

# ----------------------------- 1. 定位最新 breeding 目录 --------------------
find_latest_breeding_dir <- function(base_path) {
 
  sub_dirs <- list.dirs(base_path, recursive = FALSE, full.names = TRUE)
 
  breeding_candidates <- file.path(sub_dirs, "breeding")
  breeding_candidates <- breeding_candidates[dir.exists(breeding_candidates)]
  
  if (length(breeding_candidates) == 0) {
 
    all_dirs <- list.dirs(base_path, recursive = TRUE, full.names = TRUE)
    breeding_candidates <- all_dirs[grepl("/breeding$", all_dirs)]
  }
  
  if (length(breeding_candidates) == 0) {
    stop("错误：未找到任何 breeding 目录，请检查 BASE_PATH 设置。")
  }
  
  
  dir_info <- file.info(breeding_candidates)
  latest_dir <- rownames(dir_info)[which.max(dir_info$mtime)]
  cat("自动选择最新的 breeding 目录:", latest_dir, "\n")
  return(latest_dir)
}

# ----------------------------- 2. 自动选择最新表型/基因型文件 ----------------
find_latest_file <- function(dir_path, pattern_keywords, allowed_ext = c("txt", "csv", "hmp.txt")) {
  # 列出目录下所有文件
  all_files <- list.files(dir_path, full.names = FALSE)
  # 匹配关键词（不区分大小写）
  matched <- grep(paste(pattern_keywords, collapse = "|"), all_files, ignore.case = TRUE, value = TRUE)
  if (length(matched) == 0) {
    stop(paste("未找到匹配关键词", paste(pattern_keywords, collapse=","), "的文件"))
  }
  # 进一步按扩展名过滤
  ext_pattern <- paste0("\\.(", paste(allowed_ext, collapse = "|"), ")$")
  matched <- grep(ext_pattern, matched, ignore.case = TRUE, value = TRUE)
  if (length(matched) == 0) {
    stop(paste("未找到扩展名为", paste(allowed_ext, collapse=","), "的文件"))
  }
  # 按修改时间取最新
  file_paths <- file.path(dir_path, matched)
  file_info <- file.info(file_paths)
  latest <- matched[which.max(file_info$mtime)]
  cat("选择最新文件:", latest, "\n")
  return(latest)
}

# ----------------------------- 3. 主程序 ------------------------------------
main <- function() {
  
  args <- commandArgs(trailingOnly = TRUE)
  if (length(args) >= 1) {
    work_dir <- args[1]
    if (!dir.exists(work_dir)) stop("指定的目录不存在: ", work_dir)
    cat("手动指定 breeding 目录:", work_dir, "\n")
  } else {
    work_dir <- find_latest_breeding_dir(BASE_PATH)
  }
  
  setwd(work_dir)
  cat("工作目录已设置为:", getwd(), "\n")
  
  if (!file.exists(GAPIT_FUN)) {
    stop("GAPIT 函数文件不存在: ", GAPIT_FUN)
  }
  source(GAPIT_FUN)
  
  
  pheno_file <- find_latest_file(work_dir, pattern_keywords = c("pheno", "phenotype"), 
                                 allowed_ext = c("txt", "csv"))
 
  geno_file <- find_latest_file(work_dir, pattern_keywords = c("geno", "hmp", "hapmap"),
                                allowed_ext = c("txt", "hmp.txt", "csv"))
  
  
  cat("读取表型文件:", pheno_file, "\n")
  pheno_data <- read.csv(pheno_file, header = TRUE)
  cat("读取基因型文件:", geno_file, "\n")
  hmp_data <- read.table(geno_file, header = FALSE, stringsAsFactors = FALSE, sep = "\t")
  
  # -------------------------- 数据清洗 ---------------------------------------
  # 过滤标记（保留格式如 A/G 的标记）
  n <- nrow(hmp_data)
  valid <- rep(FALSE, n)
  valid[1] <- TRUE   
  if (n > 1) {
    valid[2:n] <- grepl("^[^/]+/[^/]+$", hmp_data$V2[2:n])
  }
  hmp_data <- hmp_data[valid, ]
  rownames(hmp_data) <- NULL
  
  # 运行 GAPIT 获取 GD、GM、kinship、PCA
  myGAPIT <- GAPIT(
    G = hmp_data,
    PCA.total = 3,
    file.output = FALSE
  )
  myGD  <- myGAPIT$GD  
  myGM  <- myGAPIT$GM   
  myKI  <- myGAPIT$kinship
  myPCA <- myGAPIT$PCA
  
  # 构建协变量：性别、年龄 + PCA
  cv_cols <- grep("gender|age", names(pheno_data), value = TRUE, ignore.case = TRUE)
  CV <- pheno_data[, c(1, which(names(pheno_data) %in% cv_cols)), drop = FALSE]
  colnames(CV)[1] <- "ID"
  myCV <- merge(CV, myPCA[, c("taxa", "PC1", "PC2", "PC3")], by.x = "ID", by.y = "taxa")
  num_cv <- ncol(myCV) - 1   
  
  # 只保留共同个体（同时存在于基因型和协变量中）
  common_ids <- intersect(myGD[,1], myCV$ID)
  cat("共同个体数:", length(common_ids), "\n")
  if (length(common_ids) == 0) stop("无共同个体，请检查ID匹配")
  
  myGD   <- myGD[myGD[,1] %in% common_ids, ]
  myCV   <- myCV[myCV$ID %in% common_ids, ]
  pheno_data <- pheno_data[pheno_data[,1] %in% common_ids, ]  # 第一列为ID
  
  
  # 筛选数值型性状列（排除ID和协变量列）
  all_candidate_traits <- setdiff(names(pheno_data)[-1], cv_cols)
  is_numeric <- sapply(pheno_data[, all_candidate_traits, drop = FALSE], is.numeric)
  trait_cols <- all_candidate_traits[is_numeric]
  cat("待分析性状:", paste(trait_cols, collapse=", "), "\n")
  if(length(trait_cols) == 0) stop("没有可分析的数值型性状")
  
  # -------------------------- 并行计算 ---------------------------------------
  ncores <- min(detectCores(), 8, length(trait_cols))
  cl <- makeCluster(ncores)
  registerDoParallel(cl)
  

  results <- foreach(trait_name = trait_cols,
                     .packages = c("BGLR", "data.table"),
                     .export = c("myGD", "myGM", "myKI", "myCV", "pheno_data", "hmp_data", "num_cv", "common_ids", "GAPIT_FUN")) %dopar% {
                       
                    
                       source(GAPIT_FUN)
                       
                       cat("\n====================\n")
                       cat("处理性状:", trait_name, "\n")
                       cat("====================\n")
                       
                       Y_full <- pheno_data[, c(1, which(names(pheno_data) == trait_name)), drop = FALSE]
                       colnames(Y_full) <- c("ID", "trait_value")
                       
                       # ----- 1. GAGBLUP  -----
                       fit_gagblup <- GAPIT(
                         Y = Y_full,
                         G = hmp_data,
                         CV = myCV,
                         model = "Blink",
                         buspred = TRUE,
                         lmpred = FALSE,
                         CV.Extragenetic = num_cv,
                         file.output = FALSE
                       )
                       pred_gag <- fit_gagblup$Pred
                       temp_gag <- data.frame(ID = Y_full$ID)
                       temp_gag[[paste0(trait_name, "_Observed")]] <- Y_full$trait_value
                       temp_gag[[paste0(trait_name, "_Genetic")]] <- pred_gag$gBreedingValue[match(temp_gag$ID, pred_gag$Taxa)]
                       temp_gag[[paste0(trait_name, "_Pred")]]      <- pred_gag$Prediction[match(temp_gag$ID, pred_gag$Taxa)]
                       
                       # ----- 2. gBLUP -----
                       fit_gblup <- GAPIT(
                         Y = Y_full,
                         G = hmp_data,
                         CV = myCV,
                         KI = myKI,
                         model = "gBLUP",
                         buspred = FALSE,
                         CV.Extragenetic = num_cv,
                         file.output = FALSE
                       )
                       pred_gblup <- fit_gblup$Pred
                       temp_gblup <- data.frame(ID = Y_full$ID)
                       temp_gblup[[paste0(trait_name, "_Observed")]] <- Y_full$trait_value
                       temp_gblup[[paste0(trait_name, "_Genetic")]] <- pred_gblup$gBreedingValue[match(temp_gblup$ID, pred_gblup$Taxa)]
                       temp_gblup[[paste0(trait_name, "_Pred")]]      <- pred_gblup$Prediction[match(temp_gblup$ID, pred_gblup$Taxa)]
                       
                       # ----- 3. BayesB (BGLR) -----
                       all_ids <- common_ids
                       Y_train <- Y_full[!is.na(Y_full$trait_value), ]
                       if(nrow(Y_train) == 0) {
                         warning("性状 ", trait_name, " 无有效观测值，跳过 BayesB")
                         temp_bayes <- data.frame(ID = all_ids)
                         temp_bayes[[paste0(trait_name, "_Observed")]] <- Y_full$trait_value[match(all_ids, Y_full$ID)]
                         temp_bayes[[paste0(trait_name, "_Genetic")]] <- NA
                         temp_bayes[[paste0(trait_name, "_Pred")]] <- NA
                       } else {
                         # 对齐训练集
                         CV2 <- myCV[match(Y_train$ID, myCV$ID), ]
                         GD2 <- myGD[match(Y_train$ID, myGD[,1]), ]
                         
                         y <- Y_train$trait_value
                         names(y) <- Y_train$ID
                         
                         # 协变量矩阵
                         CV_matrix <- as.matrix(CV2[, -1, drop = FALSE])
                         mode(CV_matrix) <- "numeric"
                         rownames(CV_matrix) <- CV2$ID
                         
                         # 基因型矩阵
                         geno <- as.matrix(GD2[, -1, drop = FALSE])
                         mode(geno) <- "numeric"
                         rownames(geno) <- GD2[,1]
                         
                         # 缺失值插补（列均值）
                         if(any(is.na(geno))) {
                           for(j in 1:ncol(geno)) {
                             geno[is.na(geno[,j]), j] <- mean(geno[,j], na.rm = TRUE)
                           }
                         }
                         if(any(is.na(CV_matrix))) {
                           for(j in 1:ncol(CV_matrix)) {
                             CV_matrix[is.na(CV_matrix[,j]), j] <- mean(CV_matrix[,j], na.rm = TRUE)
                           }
                         }
                         
                         # 运行 BGLR
                         set.seed(123)
                         ETA <- list(
                           SNP = list(X = geno, model = "BayesB"),
                           FIXED = list(X = CV_matrix, model = "FIXED")
                         )
                         fm <- BGLR(y = y, ETA = ETA, nIter = 200000, burnIn = 160000, thin = 10, verbose = FALSE)
                         
                         # 预测全体个体
                         CV_all <- myCV[match(all_ids, myCV$ID), -1, drop = FALSE]
                         CV_all <- as.matrix(CV_all)
                         mode(CV_all) <- "numeric"
                         rownames(CV_all) <- all_ids
                         
                         GD_all <- myGD[match(all_ids, myGD[,1]), -1, drop = FALSE]
                         GD_all <- as.matrix(GD_all)
                         mode(GD_all) <- "numeric"
                         rownames(GD_all) <- all_ids
                         
                         fixed_pred <- as.vector(CV_all %*% fm$ETA$FIXED$b)
                         genetic_pred <- as.vector(GD_all %*% fm$ETA$SNP$b)
                         pred_all <- fm$mu + fixed_pred + genetic_pred
                         names(pred_all) <- all_ids
                         
                         obs_all <- Y_full$trait_value[match(all_ids, Y_full$ID)]
                         
                         temp_bayes <- data.frame(ID = all_ids)
                         temp_bayes[[paste0(trait_name, "_Observed")]] <- obs_all
                         temp_bayes[[paste0(trait_name, "_Genetic")]] <- genetic_pred
                         temp_bayes[[paste0(trait_name, "_Pred")]] <- pred_all
                       }
                       
                       list(gag = temp_gag, gblup = temp_gblup, bayes = temp_bayes)
                     }
  
  stopCluster(cl)
  
  # 合并所有性状的结果
  ALL_GAGBLUP <- Reduce(function(x, y) merge(x, y, by = "ID", all = TRUE), 
                        lapply(results, `[[`, "gag"))
  ALL_gBLUP   <- Reduce(function(x, y) merge(x, y, by = "ID", all = TRUE), 
                        lapply(results, `[[`, "gblup"))
  ALL_BayesB  <- Reduce(function(x, y) merge(x, y, by = "ID", all = TRUE), 
                        lapply(results, `[[`, "bayes"))
  
  # 写入结果
  write.csv(ALL_GAGBLUP, "All_GAGBLUP_result.csv", row.names = FALSE)
  write.csv(ALL_gBLUP,   "All_gBLUP_result.csv",   row.names = FALSE)
  write.csv(ALL_BayesB,  "All_BayesB_result.csv",  row.names = FALSE)
  
  cat("\n分析完成！结果已保存至:", work_dir, "\n")
}

main()
