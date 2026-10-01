import { IsEnum, IsNotEmpty, IsInt, Min, Max, IsOptional, IsObject, IsUUID, IsDateString } from 'class-validator';

export enum RiskLevel {
  LOW = 'LOW',
  MEDIUM = 'MEDIUM',
  HIGH = 'HIGH',
  VERY_HIGH = 'VERY_HIGH',
  PEP = 'PEP',
}

export class ClassifyRiskDto {
  @IsUUID()
  @IsNotEmpty()
  customerId: string;

  @IsEnum(RiskLevel)
  @IsNotEmpty()
  riskLevel: RiskLevel;

  @IsInt()
  @Min(0)
  @Max(1000)
  @IsOptional()
  riskScore?: number;

  @IsObject()
  @IsOptional()
  riskFactors?: Record<string, any>;

  @IsDateString()
  @IsOptional()
  nextReviewDate?: string;
}
