# This Rscript would take a processed measured data file as input, and do the following steps:
# 1.Import the protein data and network file(as edge list) from csv files
# 2.Import matrix for RNA, CNV and mutation as predictors
# 3.Select predictors based on heat diffusion from response in the network
# 4.Construct the LASSO model: PeptideA_site1 ~ PeptideA_site1 + PeptideA_site2...
# 5.Evaluate the model with r-square and q-square
# input files:
# 1. measure_filename are processed quantitive data for phos protein
# 2. heat_influence_file: file for heat influence matrix
# 3. network_file: file for pathway network
# 4. mut_filename/rna_filename/cnv_filename is info about mutations/expression/copy_number info on each sample
# output files:
# 1.result_matrix is the prediction versus true value from Nested cross validation, it also contains the value for hyperparameters trained from inner loop
# 2.beta_matrix is the table for coefficient from different testsets.

library(glmnet)
library(methods)

# Set inputs:
rna_filename          = '~/Documents/workspace/phospho_network/RAWDATA/tcga_brac/BRCA.exp.547.med.txt'
cnv_filename          = '~/Documents/workspace/phospho_network/script_files/TCGA_analysis/cnv_processed.csv'
mut_filename          = '~/Documents/workspace/phospho_network/script_files/TCGA_analysis/mutation_matrix_classified.csv'
heat_influence_file   = '~/Documents/workspace/phospho_network/script_files/TCGA_analysis/heat_influence.csv'
network_file          = '~/Documents/workspace/temp_files/network_all_rna.csv'

# target value input:
mdata_filename        = '~/Documents/workspace/phospho_network/script_files/TCGA_analysis/rppa_processed.csv'

# Set parameters
result_path       = '~/Documents/workspace/phospho_network/script_files/TCGA_analysis'
result_outfiles   = c('result_matrix_no_network.csv','beta_matrix_no_network.csv')

k                 = 0.01  # a parameter to define the extend of predictors by keep nodes receive more heat than k*(heat_response_CNV)
alphas            = c(1) #seq(0,1,0.05)
lambdas           = c()
outerfold         = 10
innerfold         = 9
i_penalty         = F # use different penalty based on heat diffusion?

# Functions:
# create vector for predictors with heat by heat diffusion
# test_node is in protein_site or gene_site format, both test_gene and test_node must in the constructed pathway network
predictor_construct <- function(test_node,hi_matrix,k = 1,test_gene = NULL){
  if(is.null(test_gene)){
    test_gene <- unique(gsub('(\\w+)_\\w+','\\1',test_node))
  }
  #create heat flow by heat influence and test_node
  heat_input <- matrix(0,nrow(hi_matrix),nrow(hi_matrix))
  colnames(heat_input) <- colnames(hi_matrix)
  rownames(heat_input) <- colnames(hi_matrix)
  diag(heat_input)[test_node] <- 1/length(test_node)
  heat_flow <- hi_matrix %*% heat_input
  heat_flow2 <- apply(heat_flow,1,sum)
  predictors <- heat_flow2[heat_flow2 >= min(k*heat_flow2[paste(test_gene,'CNV',sep = '_')])]
  return(predictors)
}

# given a site_id, return a list with list$x are the predictors, and list$y are true responses
data_prepare <- function(test_name,mdata,mut_data,cnv_data,rna_data,predictors,i_penalty){
  # add rna info
  rna_predictors <- predictors[grep('_RNA',names(predictors))]
  rna_symbol <- gsub('(.+)_RNA','\\1',names(rna_predictors))
  rna_symbol <- rna_symbol[rna_symbol %in% rownames(rna_data)]
  rna_x <- t(rna_data[rna_symbol,])
  if(ncol(rna_x)>0){
    colnames(rna_x) <- paste(colnames(rna_x),'RNA',sep = '_')
  }
  # add cnv info
  cnv_predictors <- predictors[grep('_CNV',names(predictors))]
  cnv_symbol <- gsub('(.+)_CNV','\\1',names(cnv_predictors))
  cnv_symbol <- cnv_symbol[cnv_symbol %in% rownames(cnv_data)]
  cnv_x <- t(cnv_data[cnv_symbol,])
  if(ncol(cnv_x)>0){
    colnames(cnv_x) <- paste(colnames(cnv_x),'CNV',sep = '_')
  }
  # add mutation information
  mut_predictors <- predictors[grep('_mutation',names(predictors))]
  mut_symbol <- gsub('(.+)_mutation','\\1',names(mut_predictors))
  mut_symbol <- mut_symbol[mut_symbol %in% rownames(mut_data)]
  mut_x <- t(mut_data[mut_symbol,])
  if(ncol(mut_x)>0){
    mut_x2 <- apply((!(mut_x == '' | mut_x == 0)),2,as.numeric)
    colnames(mut_x2) <- paste(colnames(mut_x),'mutation',sep = '_')
    rownames(mut_x2) <- rownames(mut_x)
    
  }
  data_x <- cbind(rna_x,cnv_x,mut_x2)
  if(ncol(data_x) <= 2){return (NULL)}
  data_x <- apply(data_x,2,as.numeric)
  valid_sample <- apply(data_x,1,function(x)sum(is.na(x))==0)
  data_x <- data_x[valid_sample,]
  pen_vec <- abs(log(predictors[colnames(data_x)]))
  # return x and y
  data_model <- list()
  data_model$x <- data_x
  data_model$y <- as.numeric(t(mdata[test_name,]))[valid_sample]
  if(max(pen_vec) == min(pen_vec) | !i_penalty){
    penalty <- predictors/predictors
  }else{
    penalty <- (pen_vec-min(pen_vec))/(max(pen_vec)-min(pen_vec))
  }
  data_model$penalty <- penalty
  data_model$site_id <- test_name
  return (data_model)
}

# Nested cross validation: alpha and lambda are vectors for grid search, if lambda is set to NULL, it would train alpha only and let glmnet to decide lambda
# inner loop would use a leave-1-out CV, outer loop would have ntest for test set.
nestcv <- function(model_data,alphas,lambdas = NULL,outerfold = 3,innerfold = 10){
  penalty         <- model_data$penalty
  test_list       <- list()
  sample_list     <- 1:nrow(model_data$x)
  sample_list_tmp <- sample(sample_list,size = floor(length(sample_list)/outerfold)*outerfold)
  test_size <- floor(nrow(model_data$x)/outerfold)
  for (i in 1:outerfold){
    test_list[[i]] <- sample_list_tmp[1:test_size]
    sample_list_tmp <- sample_list_tmp[-(1:test_size)]
  }
  result_matrix <- matrix(0,nrow = 0,ncol = 6)
  colnames(result_matrix) <- c('gene_site','test_set','alpha','predict_value','true_value','best_outer_q2')
  beta_matrix_raw <- matrix(0,nrow = 0,ncol = ncol(model_data$x))
  outer_pred_list <- rep(0,nrow(model_data$x))
  # outer loop
  for (i in 1:outerfold){
    outer_train_set <- sample_list[-test_list[[i]]]
    outer_test_set  <- test_list[[i]]
    best_alpha <- 0
    best_err   <- Inf
    # inner loop
    for(alpha in alphas){
      cv_model <- cv.glmnet(model_data$x[-test_list[[i]],],model_data$y[-test_list[[i]]],nfolds = innerfold,penalty.factor = model_data$penalty,alpha = alpha,grouped=FALSE)
      return_err <- min(cv_model$cvm)
      if(return_err < best_err){
        best_alpha <- alpha
        best_model <- cv_model$glmnet.fit
      }
    }
    #end on inner loop
    # use best alpha on test data
    test_x <- model_data$x[outer_test_set,]
    if(outerfold == nrow(model_data$x)){
      test_x <- t(test_x)
    }
    outer_test_pred <- predict(best_model,newx = test_x,s = cv_model$lambda.min)
    result_matrix <- rbind(result_matrix,cbind(rep(model_data$site_id,length(outer_test_set)),outer_test_set,rep(best_alpha,length(outer_test_set)),outer_test_pred,model_data$y[outer_test_set],rep(0,length(outer_test_set))))
    
    beta_matrix_raw <- rbind(beta_matrix_raw,best_model$beta[,which.max(best_model$dev.ratio)])
  }
  pred_all <- as.numeric(result_matrix[,'true_value'])
  outer_q2 <- 1 - sum((as.numeric(result_matrix[,'predict_value'])-pred_all)^2)/sum((pred_all-mean(pred_all))^2)
  
  beta_matrix <- t(rbind(rep(model_data$site_id,ncol(beta_matrix_raw)),colnames(model_data$x),beta_matrix_raw))
  colnames(beta_matrix) <- c('gene_site','predictor',paste('test',1:outerfold,sep = '_'))
  result_matrix[,'best_outer_q2'] <- rep(outer_q2,nrow(result_matrix))
  return(list('matrix' = result_matrix,'best_outer_q2' = outer_q2,'beta_matrix' = beta_matrix))
}

# return a matrix with all upstream nodes that are one level further(all_level=F) or every possible upstream nodes(all_level=F)
cal_q2 <- function(true,pred){
  pred <- as.numeric(pred)
  true <- as.numeric(true)
  return(1 - sum((pred-true)^2)/sum((true-mean(true))^2))
}


mdata_y_pick <- function(mdata_names){
  mdata_p <- grep('\\w+_\\w+',mdata_names,value = T)
  mdata_plist <- strsplit(mdata_p,split = '_')
  mdata_pgenes <- strsplit(unlist(lapply(mdata_plist,function(x)x[1])),split = ';')
  mdata_psites <- strsplit(unlist(lapply(mdata_plist,function(x)x[2])),split = ';')
  mdata_pnodes <- c()
  for(i in 1:length(mdata_pgenes)){
    new_nodes=expand.grid(mdata_pgenes[[i]],mdata_psites[[i]])
    mdata_pnodes <- c(mdata_pnodes,paste(paste(new_nodes$Var1,new_nodes$Var2,sep = '_'),collapse = ';'))
  }
  return(cbind(mdata_p,mdata_pnodes))
}

# Main
# import dataset
mdata <- read.csv(mdata_filename,row.names = 1)
mut_data  <- read.csv(mut_filename,as.is = T,row.names = 1)
rna_data_raw  <- read.table(rna_filename,as.is = T,row.names = 1,fill = NA)
rna_data <- rna_data_raw[-1,]
colnames(rna_data) <- gsub('-','.',rna_data_raw[1,],fixed = T)
colnames(rna_data) <- gsub(pattern = '(\\w+\\.\\w+\\.\\w+\\.\\d+).+',replacement = '\\1',x = colnames(rna_data))
cnv_data  <- read.csv(cnv_filename,as.is = T,row.names = 1)
colnames(mut_data) <- gsub(pattern = '(\\w+\\.\\w+\\.\\w+\\.\\d+).+',replacement = '\\1',x = colnames(mut_data))

# import network
network   <- as.matrix(read.csv(network_file,row.names = 1))
# hi_matrix <- as.matrix(read.csv(heat_influence_file,row.names = 1))

#filter response avaliable in the network
response_list <- mdata_y_pick(rownames(mdata))
node_all <- rownames(network)

# sample_intersect <- Reduce(intersect, list(colnames(mdata),colnames(rna_data),colnames(cnv_data)))
sample_intersect <- intersect(colnames(mdata),colnames(rna_data))
mdata_intersect <- mdata[,sample_intersect]
rna_data_intersect <- rna_data[,sample_intersect]

# samples missing CNV would considered a score as 0 for every gene copy
cnv_missing <- sample_intersect[!sample_intersect%in%colnames(cnv_data)]
cnv_missing_data <- matrix(0,ncol = length(cnv_missing),nrow = nrow(cnv_data))
colnames(cnv_missing_data) <- cnv_missing
cnv_data2 <- cbind(cnv_data,cnv_missing_data)
cnv_data_intersect <- cnv_data2[,sample_intersect]

# samples missing mutation would considered a score as 0 for every gene
mut_missing <- sample_intersect[!sample_intersect%in%colnames(mut_data)]
mut_missing_data <- matrix(0,ncol = length(mut_missing),nrow = nrow(mut_data))
colnames(mut_missing_data) <- mut_missing
mut_data2 <- cbind(mut_data,mut_missing_data)
mut_data_intersect <- mut_data2[,sample_intersect]

# regression alalysis
result_matrix <- matrix(0,nrow = 0,ncol = 6)
beta_matrix   <- matrix(0,nrow = 0,ncol = 2+outerfold)
colnames(beta_matrix)   <- c('gene_site','predictor',paste('test',1:outerfold,sep = '_'))
colnames(result_matrix) <- c('gene_site', 'test_set', 'alpha', 'predict_value', 'true_value', 'best_outer_q2')

# use all data as predictors
predictors_clique <- rep(1,nrow(network))
names(predictors_all) <- rownames(network)

for(test_name in response_list[,1]){
  print(test_name)
  test_node <- strsplit(response_list[response_list[,1] == test_name,2],split = ';')[[1]]
  test_node_valid <- test_node[test_node %in% node_all]
  if(length(test_node_valid) == 0){
    test_node_valid <- unique(gsub('(\\w+)_\\w+','\\1',test_node))
    test_node_valid <- test_node_valid[test_node_valid %in% node_all]
  }
  if(length(test_node_valid)>0){
    # predictors <- predictor_construct(test_node_valid,hi_matrix,k)
    predictors <- predictors_all
    model_data <- data_prepare(test_name = test_name,mdata = mdata_intersect,mut_data = mut_data_intersect,
                               cnv_data = cnv_data_intersect,rna_data = rna_data_intersect,predictors = predictors,i_penalty=i_penalty)
    if (!is.null(model_data)){
      model_result  <- nestcv(model_data,alphas = alphas,outerfold = outerfold,innerfold = innerfold)
      result_matrix <- rbind(result_matrix,model_result$matrix)
      beta_matrix   <- rbind(beta_matrix,model_result$beta_matrix)
    }
  }
}

write.csv(result_matrix,paste(result_path,result_outfiles[1],sep = '/'),row.names = F)
write.csv(beta_matrix,paste(result_path,result_outfiles[2],sep = '/'),row.names = F)
