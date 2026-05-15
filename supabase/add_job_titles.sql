-- Add title column to service_jobs and removal_jobs
-- Run this once in the Supabase SQL editor

alter table service_jobs add column if not exists title text not null default '';
alter table removal_jobs add column if not exists title text not null default '';
