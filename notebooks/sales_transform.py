#!/usr/bin/env python
# coding: utf-8

# ## sales_transform
# 
# New notebook

# In[ ]:


# Fabric notebook source: sales_transform
# This notebook expects the accelerator pipeline to create the sales table first.

from pyspark.sql import functions as F

source_table = "sales"
summary_table = "sales_summary_by_region"

sales_df = spark.table(source_table)

summary_df = (
    sales_df
    .groupBy("Region")
    .agg(
        F.count("*").alias("OrderCount"),
        F.sum("SalesAmount").alias("TotalSalesAmount"),
        F.avg("SalesAmount").alias("AverageSalesAmount"),
        F.min("OrderDate").alias("FirstOrderDate"),
        F.max("OrderDate").alias("LastOrderDate"),
    )
    .orderBy("Region")
)

summary_df.write.mode("overwrite").format("delta").saveAsTable(summary_table)

display(summary_df)

