import {
  IsInt,
  IsNotEmpty,
  IsOptional,
  IsString,
  IsUUID,
  MaxLength,
  Min,
} from 'class-validator';

export class ConfigureApprovalPolicyDto {
  @IsString()
  @IsNotEmpty()
  @MaxLength(150)
  policyName: string;

  @IsString()
  @IsNotEmpty()
  @MaxLength(100)
  entityType: string;

  @IsString()
  @IsNotEmpty()
  @MaxLength(100)
  actionType: string;

  @IsInt()
  @Min(0)
  minAmount: number;

  @IsInt()
  @IsOptional()
  @Min(0)
  maxAmount?: number;

  @IsInt()
  @Min(1)
  requiredApprovers: number;

  @IsUUID()
  @IsOptional()
  approverRoleId?: string;
}
